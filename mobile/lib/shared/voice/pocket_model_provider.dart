import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'pocket_model_downloader.dart';

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
  final int downloaded;
  final int total;
  final String? path;
  final String? message;

  const PocketModelState({
    required this.phase,
    this.downloaded = 0,
    this.total = 0,
    this.path,
    this.message,
  });

  double get progress => total == 0 ? 0 : downloaded / total;
}

final pocketModelDownloaderProvider = Provider<PocketModelDownloader>(
  (_) => PocketModelDownloader(),
);

final pocketModelProvider =
    NotifierProvider<PocketModelNotifier, PocketModelState>(
      PocketModelNotifier.new,
    );

class PocketModelNotifier extends Notifier<PocketModelState> {
  PocketModelDownloader? _active;

  @override
  PocketModelState build() {
    ref.onDispose(() => _active?.cancel());
    Future<void>.microtask(check);
    return const PocketModelState(phase: PocketModelPhase.checking);
  }

  Future<void> check() async {
    final downloader = ref.read(pocketModelDownloaderProvider);
    if (await downloader.isReady()) {
      final directory = await downloader.modelDirectory();
      state = PocketModelState(
        phase: PocketModelPhase.ready,
        path: directory.path,
      );
    } else {
      state = const PocketModelState(phase: PocketModelPhase.absent);
    }
  }

  Future<void> download() async {
    if (_active != null) return;
    final downloader = ref.read(pocketModelDownloaderProvider);
    _active = downloader;
    try {
      final directory = await downloader.install((downloaded, total, _) {
        state = PocketModelState(
          phase: PocketModelPhase.downloading,
          downloaded: downloaded,
          total: total,
        );
      });
      state = const PocketModelState(phase: PocketModelPhase.verifying);
      if (!await downloader.verify(directory, hashContents: false)) {
        throw const PocketModelDownloadException(
          'Pocket model verification failed.',
        );
      }
      state = PocketModelState(
        phase: PocketModelPhase.ready,
        path: directory.path,
      );
    } on PocketDownloadCancelled {
      state = const PocketModelState(phase: PocketModelPhase.cancelled);
    } on PocketInsufficientSpace {
      state = PocketModelState(
        phase: PocketModelPhase.insufficientSpace,
        message: 'Not enough free space for Pocket voice.',
      );
    } on FileSystemException catch (error) {
      state = PocketModelState(
        phase: PocketModelPhase.error,
        message: error.osError?.errorCode == 28
            ? 'Pocket voice ran out of disk space.'
            : 'Pocket voice storage failed: ${error.message}',
      );
    } catch (error) {
      state = PocketModelState(
        phase: PocketModelPhase.error,
        message: error.toString(),
      );
    } finally {
      _active = null;
    }
  }

  void cancel() => _active?.cancel();
}
