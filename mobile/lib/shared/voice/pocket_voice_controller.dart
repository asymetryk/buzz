import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../relay/relay.dart';
import 'pocket_model_provider.dart';
import 'pocket_voice_worker.dart';
import 'voice_audio_output.dart';

enum PocketVoicePhase { off, loading, listening, synthesizing, speaking, error }

@immutable
class PocketVoiceState {
  final PocketVoicePhase phase;
  final String? conversationKey;
  final String? error;

  const PocketVoiceState({
    this.phase = PocketVoicePhase.off,
    this.conversationKey,
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
      await _ensureWorker(model.path!);
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

  Future<PocketVoiceWorker> _ensureWorker(String modelPath) {
    final worker = _worker;
    if (worker != null && worker.isReady) return Future.value(worker);
    final starting = _workerStart;
    if (starting != null) return starting;

    final created = ref.read(pocketVoiceWorkerFactoryProvider)();
    _worker = created;
    _workerSubscription = created.responses.listen(_handleWorkerResponse);
    final future = created.start(modelPath).then((_) => created);
    _workerStart = future;
    return () async {
      try {
        return await future;
      } catch (error, stackTrace) {
        if (identical(_worker, created)) {
          _worker = null;
          await _workerSubscription?.cancel();
          _workerSubscription = null;
        }
        await created.dispose();
        Error.throwWithStackTrace(error, stackTrace);
      } finally {
        if (identical(_workerStart, future)) _workerStart = null;
      }
    }();
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
        _failPlayback(response.message);
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
        _failPlayback(error.toString());
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
    state = PocketVoiceState(
      phase: PocketVoicePhase.speaking,
      conversationKey: state.conversationKey,
    );
  }

  void _handleAudioEvent(VoiceAudioEvent event) {
    switch (event) {
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
        if (_playbackActive) _failPlayback('Pocket voice playback failed.');
      case VoiceAudioEvent.interrupted:
      case VoiceAudioEvent.routeLost:
      case VoiceAudioEvent.backgrounded:
        unawaited(interrupt());
    }
  }

  void _failPlayback(String message) {
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
