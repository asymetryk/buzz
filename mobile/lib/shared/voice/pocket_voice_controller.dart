import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../relay/relay.dart';
import 'pocket_model_provider.dart';
import 'pocket_voice_worker.dart';
import 'voice_audio_output.dart';

enum PocketVoicePhase { off, loading, listening, synthesizing, speaking, error }

enum PocketVoiceFailureKind { load, synthesis, playback }

@immutable
class PocketVoiceState {
  final PocketVoicePhase phase;
  final String? conversationKey;
  final PocketVoiceFailureKind? failureKind;
  final String? error;

  const PocketVoiceState({
    this.phase = PocketVoicePhase.off,
    this.conversationKey,
    this.failureKind,
    this.error,
  });

  bool get enabled => phase != PocketVoicePhase.off;
}

final voiceAudioOutputProvider = Provider<VoiceAudioOutput>(
  (_) => PlatformVoiceAudioOutput(),
);

final pocketVoiceWorkerFactoryProvider = Provider<PocketVoiceWorker Function()>(
  (_) => PocketVoiceWorker.new,
);

final pocketVoiceProvider =
    NotifierProvider<PocketVoiceNotifier, PocketVoiceState>(
      PocketVoiceNotifier.new,
    );

class PocketVoiceNotifier extends Notifier<PocketVoiceState> {
  final Queue<String> _utterances = Queue();
  final Queue<PocketWorkerAudio> _audio = Queue();
  PocketVoiceWorker? _worker;
  Future<PocketVoiceWorker>? _workerStart;
  String? _workerStartingModelPath;
  int? _workerStartingPrecision;
  String? _workerModelPath;
  int? _workerPrecision;
  StreamSubscription<PocketWorkerResponse>? _workerSubscription;
  StreamSubscription<VoiceAudioEvent>? _audioSubscription;
  int _transitionEpoch = 0;
  int _nextGeneration = 0;
  int? _activeGeneration;
  bool _synthesisComplete = false;
  bool _playbackActive = false;
  bool _stopping = false;
  bool _queueWhileStopping = false;
  Future<void>? _stopFuture;

  @override
  PocketVoiceState build() {
    ref.listen(relayConfigProvider, (previous, _) {
      if (previous != null) unawaited(disable());
    });
    ref.listen(pocketModelProvider, (_, model) {
      if (model.phase == PocketModelPhase.ready &&
          _worker != null &&
          (_workerModelPath != model.path ||
              _workerPrecision != model.variant.nativePrecision)) {
        unawaited(_replaceWorkerForModelChange());
      }
    });
    _audioSubscription = ref
        .read(voiceAudioOutputProvider)
        .events
        .listen(_handleAudioEvent);
    ref.onDispose(() {
      _transitionEpoch += 1;
      _workerSubscription?.cancel();
      _audioSubscription?.cancel();
      _worker?.cancel();
      unawaited(_worker?.dispose());
    });
    return const PocketVoiceState();
  }

  Future<void> enable(String conversationKey) async {
    if (state.conversationKey == conversationKey && state.enabled) return;
    final epoch = ++_transitionEpoch;
    await _stopConversation(preserveIncoming: false);
    if (epoch != _transitionEpoch) return;

    final model = ref.read(pocketModelProvider);
    if (model.phase != PocketModelPhase.ready || model.path == null) {
      throw StateError('Download Pocket voice before starting a conversation.');
    }
    state = PocketVoiceState(
      phase: PocketVoicePhase.loading,
      conversationKey: conversationKey,
    );
    try {
      await _ensureWorker(model.path!, model.variant.nativePrecision);
      if (epoch != _transitionEpoch) return;
      state = PocketVoiceState(
        phase: PocketVoicePhase.listening,
        conversationKey: conversationKey,
      );
      _startNextUtterance();
    } catch (error) {
      if (epoch == _transitionEpoch) {
        state = PocketVoiceState(
          phase: PocketVoicePhase.error,
          conversationKey: conversationKey,
          failureKind: PocketVoiceFailureKind.load,
          error: error.toString(),
        );
      }
      rethrow;
    }
  }

  Future<void> disable() async {
    _transitionEpoch += 1;
    state = const PocketVoiceState();
    await _stopConversation(preserveIncoming: false);
  }

  /// Stops playback and releases the resident engine before model validation.
  Future<void> releaseEngineForModelSelection() async {
    await disable();
    final starting = _workerStart;
    if (starting != null) {
      try {
        await starting;
      } catch (_) {
        // Selection validation reports the candidate engine's own result.
      }
    }
    await _disposeWorker();
  }

  void speak(String conversationKey, String text) {
    if (!state.enabled || state.conversationKey != conversationKey) return;
    if (state.phase == PocketVoicePhase.error) return;
    if (_stopping && !_queueWhileStopping) return;
    final trimmed = text.trim();
    if (trimmed.length <= 1 || trimmed.startsWith('[System]')) return;
    _utterances.add(trimmed);
    _startNextUtterance();
  }

  Future<void> interrupt() async {
    final epoch = ++_transitionEpoch;
    await _stopConversation(preserveIncoming: true);
    if (epoch == _transitionEpoch && state.enabled) {
      state = PocketVoiceState(
        phase: PocketVoicePhase.listening,
        conversationKey: state.conversationKey,
      );
      _startNextUtterance();
    }
  }

  Future<PocketVoiceWorker> _ensureWorker(
    String modelPath,
    int precision,
  ) async {
    final starting = _workerStart;
    if (starting != null &&
        _workerStartingModelPath == modelPath &&
        _workerStartingPrecision == precision) {
      return starting;
    }
    if (starting != null) {
      try {
        await starting;
      } catch (_) {
        // The replacement attempt below reports its own startup result.
      }
    }

    final worker = _worker;
    if (worker != null &&
        worker.isReady &&
        _workerModelPath == modelPath &&
        _workerPrecision == precision) {
      return worker;
    }
    if (worker != null) {
      await _disposeWorker();
    }

    final created = ref.read(pocketVoiceWorkerFactoryProvider)();
    _worker = created;
    _workerSubscription = created.responses.listen(_handleWorkerResponse);
    final future = created
        .start(modelPath, precision: precision)
        .then((_) => created);
    _workerStart = future;
    _workerStartingModelPath = modelPath;
    _workerStartingPrecision = precision;
    try {
      final ready = await future;
      _workerModelPath = modelPath;
      _workerPrecision = precision;
      return ready;
    } catch (error, stackTrace) {
      if (identical(_worker, created)) {
        _worker = null;
        await _workerSubscription?.cancel();
        _workerSubscription = null;
      }
      await created.dispose();
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      if (identical(_workerStart, future)) {
        _workerStart = null;
        _workerStartingModelPath = null;
        _workerStartingPrecision = null;
      }
    }
  }

  Future<void> _replaceWorkerForModelChange() async {
    await releaseEngineForModelSelection();
  }

  Future<void> _disposeWorker() async {
    final worker = _worker;
    _worker = null;
    _workerModelPath = null;
    _workerPrecision = null;
    await _workerSubscription?.cancel();
    _workerSubscription = null;
    if (worker != null) await worker.dispose();
  }

  Future<void> _stopConversation({required bool preserveIncoming}) async {
    final activeStop = _stopFuture;
    if (activeStop != null) {
      if (!preserveIncoming) {
        _queueWhileStopping = false;
        _utterances.clear();
      }
      await activeStop;
      return;
    }
    _stopping = true;
    _queueWhileStopping = preserveIncoming;
    _utterances.clear();
    _audio.clear();
    _activeGeneration = null;
    _synthesisComplete = false;
    _playbackActive = false;
    final output = ref.read(voiceAudioOutputProvider);
    final worker = _worker;
    worker?.cancel();
    final stop = Future.wait([
      output.stop(),
      if (worker != null) worker.cancelAndWait(),
    ]);
    _stopFuture = stop;
    try {
      await stop;
    } finally {
      if (identical(_stopFuture, stop)) {
        _stopFuture = null;
        _stopping = false;
        _queueWhileStopping = false;
      }
    }
  }

  void _startNextUtterance() {
    if (_stopping ||
        _activeGeneration != null ||
        _utterances.isEmpty ||
        !state.enabled) {
      return;
    }
    final worker = _worker;
    if (worker == null || !worker.isReady) return;
    final utterance = _utterances.removeFirst();
    final generation = ++_nextGeneration;
    _activeGeneration = generation;
    _synthesisComplete = false;
    state = PocketVoiceState(
      phase: PocketVoicePhase.synthesizing,
      conversationKey: state.conversationKey,
    );
    try {
      worker.synthesize(generation, utterance);
    } catch (error) {
      _activeGeneration = null;
      state = PocketVoiceState(
        phase: PocketVoicePhase.error,
        conversationKey: state.conversationKey,
        failureKind: PocketVoiceFailureKind.synthesis,
        error: error.toString(),
      );
    }
  }

  void _handleWorkerResponse(PocketWorkerResponse response) {
    switch (response) {
      case PocketWorkerReady():
      case PocketWorkerStopped():
        return;
      case PocketWorkerDone():
        if (response.generation != _activeGeneration) return;
        _synthesisComplete = true;
        if (!_playbackActive && _audio.isEmpty) _finishUtterance();
      case PocketWorkerFailure():
        if (response.generation != _activeGeneration) return;
        if (response.kind == PocketWorkerFailureKind.cancelled) {
          _finishUtterance();
          return;
        }
        _failPlayback(
          response.message,
          failureKind: PocketVoiceFailureKind.synthesis,
        );
      case PocketWorkerAudio():
        if (response.generation != _activeGeneration) return;
        _audio.add(response);
        if (response.isLast) _synthesisComplete = true;
        unawaited(_playNextChunk());
    }
  }

  Future<void> _playNextChunk() async {
    if (_playbackActive || _audio.isEmpty || _activeGeneration == null) return;
    final activeGeneration = _activeGeneration;
    final conversationKey = state.conversationKey;
    final chunk = _audio.removeFirst();
    _playbackActive = true;
    final output = ref.read(voiceAudioOutputProvider);
    try {
      await output.play(
        chunk.data.materialize().asUint8List(),
        chunk.sampleRate,
      );
    } catch (error) {
      if (activeGeneration == _activeGeneration && state.enabled) {
        _failPlayback(
          error.toString(),
          failureKind: PocketVoiceFailureKind.playback,
        );
      }
      return;
    }
    if (activeGeneration != _activeGeneration ||
        !state.enabled ||
        state.conversationKey != conversationKey) {
      _playbackActive = false;
      await output.stop();
      return;
    }
  }

  void _handleAudioEvent(VoiceAudioEvent event) {
    switch (event) {
      case VoiceAudioEvent.started:
        if (!_playbackActive || !state.enabled) return;
        state = PocketVoiceState(
          phase: PocketVoicePhase.speaking,
          conversationKey: state.conversationKey,
        );
      case VoiceAudioEvent.completed:
        if (!_playbackActive) return;
        _playbackActive = false;
        if (_audio.isNotEmpty) {
          unawaited(_playNextChunk());
        } else if (_synthesisComplete) {
          _finishUtterance();
        } else if (state.enabled) {
          state = PocketVoiceState(
            phase: PocketVoicePhase.synthesizing,
            conversationKey: state.conversationKey,
          );
        }
      case VoiceAudioEvent.error:
        if (_playbackActive) {
          _failPlayback(
            'Pocket voice playback failed.',
            failureKind: PocketVoiceFailureKind.playback,
          );
        }
      case VoiceAudioEvent.interrupted:
      case VoiceAudioEvent.routeLost:
      case VoiceAudioEvent.backgrounded:
        unawaited(interrupt());
    }
  }

  void _failPlayback(
    String message, {
    required PocketVoiceFailureKind failureKind,
  }) {
    _worker?.cancel();
    _utterances.clear();
    _activeGeneration = null;
    _audio.clear();
    _synthesisComplete = false;
    _playbackActive = false;
    unawaited(ref.read(voiceAudioOutputProvider).stop());
    if (state.enabled) {
      state = PocketVoiceState(
        phase: PocketVoicePhase.error,
        conversationKey: state.conversationKey,
        failureKind: failureKind,
        error: message,
      );
    }
  }

  void _finishUtterance() {
    _activeGeneration = null;
    _synthesisComplete = false;
    _playbackActive = false;
    if (_utterances.isNotEmpty) {
      _startNextUtterance();
    } else if (state.enabled) {
      state = PocketVoiceState(
        phase: PocketVoicePhase.listening,
        conversationKey: state.conversationKey,
      );
    }
  }
}
