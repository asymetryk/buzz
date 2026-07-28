import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../theme/theme_provider.dart';
import 'pocket_model_downloader.dart';
import 'pocket_model_manifest.dart';
import 'pocket_voice_worker.dart';

const _pocketModelSelectionKey = 'pocket_model_precision';

enum PocketModelPhase {
  checking,
  absent,
  downloading,
  verifying,
  ready,
  cancelled,
  insufficientSpace,
  error,
}

@immutable
class PocketModelState {
  final PocketModelPhase phase;
  final PocketModelVariant variant;
  final int downloaded;
  final int total;
  final String? path;
  final String? message;

  const PocketModelState({
    required this.phase,
    this.variant = PocketModelVariant.higherQuality,
    this.downloaded = 0,
    this.total = 0,
    this.path,
    this.message,
  });

  double get progress => total == 0 ? 0 : downloaded / total;
}

final pocketModelDownloaderProvider =
    Provider.family<PocketModelDownloader, PocketModelVariant>(
      (_, variant) => PocketModelDownloader(variant: variant),
    );

typedef PocketModelValidator =
    Future<void> Function(String path, PocketModelVariant variant);

final pocketModelValidatorProvider = Provider<PocketModelValidator>(
  (_) => (path, variant) async {
    final worker = PocketVoiceWorker();
    StreamSubscription<PocketWorkerResponse>? subscription;
    try {
      await worker.start(path, precision: variant.nativePrecision);
      const generation = 1;
      var hasNonSilentPcm = false;
      final completed = Completer<void>();
      subscription = worker.responses.listen((response) {
        switch (response) {
          case PocketWorkerAudio(
            generation: generation,
            :final data,
            :final isLast,
          ):
            final bytes = data.materialize().asUint8List();
            hasNonSilentPcm =
                hasNonSilentPcm || bytes.any((sample) => sample != 0);
            if (isLast && !completed.isCompleted) {
              if (hasNonSilentPcm) {
                completed.complete();
              } else {
                completed.completeError(
                  StateError('Pocket model produced only silent audio.'),
                );
              }
            }
          case PocketWorkerDone(generation: generation):
            if (!completed.isCompleted) {
              completed.completeError(
                StateError('Pocket model produced no audio.'),
              );
            }
          case PocketWorkerFailure(generation: generation, :final message):
            if (!completed.isCompleted) {
              completed.completeError(StateError(message));
            }
          case _:
            break;
        }
      });
      worker.synthesize(generation, 'Pocket voice is ready.');
      await completed.future.timeout(const Duration(minutes: 1));
    } finally {
      await subscription?.cancel();
      await worker.dispose();
    }
  },
);

final pocketModelProvider =
    NotifierProvider<PocketModelNotifier, PocketModelState>(
      PocketModelNotifier.new,
    );

class PocketModelNotifier extends Notifier<PocketModelState> {
  PocketModelDownloader? _active;
  int _operationEpoch = 0;

  @override
  PocketModelState build() {
    ref.onDispose(() => _active?.cancel());
    final stored = ref
        .read(savedPrefsProvider)
        .getString(_pocketModelSelectionKey);
    final variant = PocketModelVariant.fromStored(stored);
    Future<void>.microtask(check);
    return PocketModelState(phase: PocketModelPhase.checking, variant: variant);
  }

  Future<void> check() async {
    final epoch = ++_operationEpoch;
    final selected = state.variant;
    final selectedDownloader = ref.read(
      pocketModelDownloaderProvider(selected),
    );
    final selectedReady = await selectedDownloader.isReady();
    if (epoch != _operationEpoch) return;
    if (selectedReady) {
      final directory = await selectedDownloader.modelDirectory();
      final obsolete = selected == PocketModelVariant.higherQuality
          ? PocketModelVariant.faster
          : PocketModelVariant.higherQuality;
      await ref.read(pocketModelDownloaderProvider(obsolete)).deleteCache();
      if (selected == PocketModelVariant.higherQuality) {
        await selectedDownloader.deleteLegacyCaches();
      }
      if (epoch != _operationEpoch) return;
      state = PocketModelState(
        phase: PocketModelPhase.ready,
        variant: selected,
        path: directory.path,
      );
      return;
    }

    final fallback = selected == PocketModelVariant.higherQuality
        ? PocketModelVariant.faster
        : PocketModelVariant.higherQuality;
    final fallbackDownloader = ref.read(
      pocketModelDownloaderProvider(fallback),
    );
    final fallbackReady = await fallbackDownloader.isReady();
    if (epoch != _operationEpoch) return;
    if (fallbackReady) {
      final directory = await fallbackDownloader.modelDirectory();
      if (epoch != _operationEpoch) return;
      await _persist(fallback);
      await selectedDownloader.deleteCache();
      if (epoch != _operationEpoch) return;
      state = PocketModelState(
        phase: PocketModelPhase.ready,
        variant: fallback,
        path: directory.path,
        message: '${selected.label} was unavailable. Using ${fallback.label}.',
      );
      return;
    }

    state = PocketModelState(phase: PocketModelPhase.absent, variant: selected);
  }

  Future<void> download() => select(state.variant);

  Future<void> select(PocketModelVariant target) async {
    if (_active != null) return;
    if (state.phase == PocketModelPhase.ready && state.variant == target) {
      return;
    }

    _operationEpoch += 1;
    final previous = state;
    final downloader = ref.read(pocketModelDownloaderProvider(target));
    _active = downloader;
    try {
      Directory directory;
      if (await downloader.isReady()) {
        directory = await downloader.modelDirectory();
      } else {
        state = PocketModelState(
          phase: PocketModelPhase.downloading,
          variant: target,
          total: target.runtimeBytes,
        );
        directory = await downloader.install((downloaded, total, _) {
          state = PocketModelState(
            phase: PocketModelPhase.downloading,
            variant: target,
            downloaded: downloaded,
            total: total,
          );
        });
      }

      state = PocketModelState(
        phase: PocketModelPhase.verifying,
        variant: target,
        path: directory.path,
      );
      await ref.read(pocketModelValidatorProvider)(directory.path, target);
      await _persist(target);
      state = PocketModelState(
        phase: PocketModelPhase.ready,
        variant: target,
        path: directory.path,
      );

      final obsolete = target == PocketModelVariant.higherQuality
          ? PocketModelVariant.faster
          : PocketModelVariant.higherQuality;
      await ref.read(pocketModelDownloaderProvider(obsolete)).deleteCache();
      if (target == PocketModelVariant.higherQuality) {
        await downloader.deleteLegacyCaches();
      }
    } on PocketDownloadCancelled {
      await downloader.deleteCache();
      _restoreOrSet(
        previous,
        PocketModelState(phase: PocketModelPhase.cancelled, variant: target),
      );
    } on PocketInsufficientSpace {
      await downloader.deleteCache();
      _restoreOrSet(
        previous,
        PocketModelState(
          phase: PocketModelPhase.insufficientSpace,
          variant: target,
          message: 'Not enough free space for ${target.label}.',
        ),
      );
    } on FileSystemException catch (error) {
      await downloader.deleteCache();
      _restoreOrSet(
        previous,
        PocketModelState(
          phase: PocketModelPhase.error,
          variant: target,
          message: error.osError?.errorCode == 28
              ? 'Pocket voice ran out of disk space.'
              : 'Pocket voice storage failed: ${error.message}',
        ),
      );
    } catch (error) {
      await downloader.deleteCache();
      _restoreOrSet(
        previous,
        PocketModelState(
          phase: PocketModelPhase.error,
          variant: target,
          message: '${target.label} is unavailable: $error',
        ),
      );
    } finally {
      _active = null;
    }
  }

  void cancel() => _active?.cancel();

  void _restoreOrSet(PocketModelState previous, PocketModelState failure) {
    if (previous.phase == PocketModelPhase.ready && previous.path != null) {
      state = PocketModelState(
        phase: PocketModelPhase.ready,
        variant: previous.variant,
        path: previous.path,
        message:
            '${failure.message ?? failure.phase.name} '
            '${previous.variant.label} was kept.',
      );
    } else {
      state = failure;
    }
  }

  Future<void> _persist(PocketModelVariant variant) async {
    final saved = await ref
        .read(savedPrefsProvider)
        .setString(_pocketModelSelectionKey, variant.precision);
    if (!saved) {
      throw StateError('Pocket model selection could not be saved.');
    }
  }
}
