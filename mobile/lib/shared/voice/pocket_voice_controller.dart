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

enum PocketVoiceBackend { none, pocket, androidSystem }

enum PocketVoiceFallbackReason {
  modelUnavailable,
  pocketLoadFailed,
  pocketSynthesisFailed,
  resourcePressure,
}

@immutable
class PocketVoiceState {
  final PocketVoicePhase phase;
  final PocketVoiceBackend backend;
  final PocketVoiceFallbackReason? fallbackReason;
  final String? conversationKey;
  final PocketVoiceFailureKind? failureKind;
  final String? error;

  const PocketVoiceState({
    this.phase = PocketVoicePhase.off,
    this.backend = PocketVoiceBackend.none,
    this.fallbackReason,
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

class _SpeechRequest {
  final String text;
  final bool systemOnly;

  const _SpeechRequest(this.text, {this.systemOnly = false});
}

class PocketVoiceNotifier extends Notifier<PocketVoiceState> {
  final Queue<_SpeechRequest> _utterances = Queue();
  final Queue<PocketWorkerAudio> _audio = Queue();
  PocketVoiceWorker? _worker;
  Future<PocketVoiceWorker>? _workerStart;
  StreamSubscription<PocketWorkerResponse>? _workerSubscription;
  StreamSubscription<VoiceAudioEvent>? _audioSubscription;
  _SpeechRequest? _activeRequest;
  PocketVoiceBackend _activeBackend = PocketVoiceBackend.none;
  int _transitionEpoch = 0;
  int _nextGeneration = 0;
  int? _activeGeneration;
  bool _synthesisComplete = false;
  bool _playbackActive = false;
  bool _stopping = false;
  bool _queueWhileStopping = false;
  bool _startingNext = false;
  bool _pocketRetryAllowed = true;
  Future<void>? _stopFuture;

  @override
  PocketVoiceState build() {
    ref.listen(relayConfigProvider, (previous, _) {
      if (previous != null) unawaited(disable());
    });
    ref.listen(pocketModelProvider, (previous, next) {
      if (next.phase == PocketModelPhase.ready &&
          previous?.phase != PocketModelPhase.ready) {
        _pocketRetryAllowed = true;
        _startNextUtterance();
      }
    });
    final output = ref.read(voiceAudioOutputProvider);
    _audioSubscription = output.events.listen(_handleAudioEvent);
    ref.onDispose(() {
      _transitionEpoch += 1;
      _workerSubscription?.cancel();
      _audioSubscription?.cancel();
      _worker?.cancel();
      unawaited(_worker?.dispose());
      unawaited(output.stop());
      unawaited(output.shutdownSystemTts());
    });
    return const PocketVoiceState();
  }

  Future<void> enable(String conversationKey) async {
    if (state.conversationKey == conversationKey && state.enabled) return;
    final epoch = ++_transitionEpoch;
    await _stopConversation(preserveIncoming: false);
    if (epoch != _transitionEpoch) return;

    _pocketRetryAllowed = true;
    state = PocketVoiceState(
      phase: PocketVoicePhase.loading,
      conversationKey: conversationKey,
    );
    final model = ref.read(pocketModelProvider);
    PocketVoiceFallbackReason fallbackReason =
        PocketVoiceFallbackReason.modelUnavailable;
    if (model.phase == PocketModelPhase.ready && model.path != null) {
      try {
        await _ensureWorker(model.path!);
        if (epoch != _transitionEpoch) return;
        state = PocketVoiceState(
          phase: PocketVoicePhase.listening,
          backend: PocketVoiceBackend.pocket,
          conversationKey: conversationKey,
        );
        _startNextUtterance();
        return;
      } catch (_) {
        fallbackReason = PocketVoiceFallbackReason.pocketLoadFailed;
        _pocketRetryAllowed = false;
        await _parkWorker();
      }
    } else {
      _pocketRetryAllowed = false;
    }

    if (epoch != _transitionEpoch) return;
    final output = ref.read(voiceAudioOutputProvider);
    if (await output.systemTtsAvailable()) {
      if (epoch != _transitionEpoch) return;
      state = PocketVoiceState(
        phase: PocketVoicePhase.listening,
        backend: PocketVoiceBackend.androidSystem,
        fallbackReason: fallbackReason,
        conversationKey: conversationKey,
      );
      _startNextUtterance();
      return;
    }

    final message = model.phase == PocketModelPhase.ready
        ? 'Pocket voice and Android system speech are unavailable.'
        : 'Download Pocket voice before starting a conversation.';
    if (epoch == _transitionEpoch) {
      state = PocketVoiceState(
        phase: PocketVoicePhase.error,
        conversationKey: conversationKey,
        failureKind: PocketVoiceFailureKind.load,
        error: message,
      );
    }
    throw StateError(message);
  }

  Future<void> disable() async {
    _transitionEpoch += 1;
    state = const PocketVoiceState();
    await _stopConversation(preserveIncoming: false);
    await ref.read(voiceAudioOutputProvider).shutdownSystemTts();
  }

  void speak(String conversationKey, String text) {
    if (!state.enabled || state.conversationKey != conversationKey) return;
    if (state.phase == PocketVoicePhase.error) return;
    if (_stopping && !_queueWhileStopping) return;
    final trimmed = text.trim();
    if (trimmed.length <= 1 || trimmed.startsWith('[System]')) return;
    _utterances.add(_SpeechRequest(trimmed));
    _startNextUtterance();
  }

  Future<void> interrupt() async {
    final epoch = ++_transitionEpoch;
    await _stopConversation(preserveIncoming: true);
    if (epoch == _transitionEpoch && state.enabled) {
      state = PocketVoiceState(
        phase: PocketVoicePhase.listening,
        backend: state.backend,
        fallbackReason: state.fallbackReason,
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

  Future<void> _parkWorker() async {
    final worker = _worker;
    if (worker == null) return;
    _worker = null;
    _workerStart = null;
    await _workerSubscription?.cancel();
    _workerSubscription = null;
    await worker.dispose();
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
    _activeRequest = null;
    _activeBackend = PocketVoiceBackend.none;
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
    if (_startingNext ||
        _stopping ||
        _activeGeneration != null ||
        _utterances.isEmpty ||
        !state.enabled ||
        state.phase == PocketVoicePhase.loading) {
      return;
    }
    _startingNext = true;
    unawaited(
      _startNextUtteranceAsync().whenComplete(() {
        _startingNext = false;
        if (_activeGeneration == null && _utterances.isNotEmpty) {
          _startNextUtterance();
        }
      }),
    );
  }

  Future<void> _startNextUtteranceAsync() async {
    final next = _utterances.first;
    if (!next.systemOnly &&
        state.backend == PocketVoiceBackend.androidSystem &&
        _pocketRetryAllowed) {
      await _tryPromotePocket();
    }
    if (_stopping || !state.enabled || _activeGeneration != null) return;

    final request = _utterances.removeFirst();
    final generation = ++_nextGeneration;
    _activeGeneration = generation;
    _activeRequest = request;
    _synthesisComplete = false;
    _playbackActive = false;

    final worker = _worker;
    if (!request.systemOnly &&
        state.backend == PocketVoiceBackend.pocket &&
        worker != null &&
        worker.isReady) {
      _activeBackend = PocketVoiceBackend.pocket;
      state = PocketVoiceState(
        phase: PocketVoicePhase.synthesizing,
        backend: PocketVoiceBackend.pocket,
        conversationKey: state.conversationKey,
      );
      try {
        worker.synthesize(generation, request.text);
      } catch (error) {
        _handlePocketFailure(
          PocketWorkerFailure(
            PocketWorkerFailureKind.synthesis,
            error.toString(),
            generation: generation,
            remainingTextChunks: [request.text],
          ),
        );
      }
      return;
    }

    _activeBackend = PocketVoiceBackend.androidSystem;
    state = PocketVoiceState(
      phase: PocketVoicePhase.synthesizing,
      backend: PocketVoiceBackend.androidSystem,
      fallbackReason: state.fallbackReason,
      conversationKey: state.conversationKey,
    );
    final output = ref.read(voiceAudioOutputProvider);
    if (!await output.systemTtsAvailable()) {
      _failAll(
        'Android system speech is unavailable.',
        failureKind: PocketVoiceFailureKind.load,
      );
      return;
    }
    if (generation != _activeGeneration || _stopping || !state.enabled) return;
    _playbackActive = true;
    try {
      await output.speakSystem(request.text, generation);
    } catch (error) {
      if (generation == _activeGeneration && state.enabled) {
        _failAll(
          error.toString(),
          failureKind: PocketVoiceFailureKind.synthesis,
        );
      }
    }
  }

  Future<void> _tryPromotePocket() async {
    final model = ref.read(pocketModelProvider);
    if (model.phase != PocketModelPhase.ready || model.path == null) {
      _pocketRetryAllowed = false;
      return;
    }
    try {
      await _ensureWorker(model.path!);
      if (_stopping || !state.enabled) return;
      state = PocketVoiceState(
        phase: PocketVoicePhase.listening,
        backend: PocketVoiceBackend.pocket,
        conversationKey: state.conversationKey,
      );
    } catch (_) {
      _pocketRetryAllowed = false;
      await _parkWorker();
    }
  }

  void _handleWorkerResponse(PocketWorkerResponse response) {
    switch (response) {
      case PocketWorkerReady():
      case PocketWorkerStopped():
        return;
      case PocketWorkerDone():
        if (response.generation != _activeGeneration ||
            _activeBackend != PocketVoiceBackend.pocket) {
          return;
        }
        _synthesisComplete = true;
        if (!_playbackActive && _audio.isEmpty) _finishUtterance();
      case PocketWorkerFailure():
        if (response.kind == PocketWorkerFailureKind.cancelled) {
          _finishUtterance();
          return;
        }
        _handlePocketFailure(response);
      case PocketWorkerAudio():
        if (response.generation != _activeGeneration ||
            _activeBackend != PocketVoiceBackend.pocket) {
          return;
        }
        _audio.add(response);
        if (response.isLast) _synthesisComplete = true;
        unawaited(_playNextChunk());
    }
  }

  void _handlePocketFailure(PocketWorkerFailure response) {
    if (response.generation != _activeGeneration ||
        _activeBackend != PocketVoiceBackend.pocket ||
        _stopping) {
      return;
    }
    _pocketRetryAllowed = false;
    final fallbackReason =
        state.fallbackReason == PocketVoiceFallbackReason.resourcePressure
        ? PocketVoiceFallbackReason.resourcePressure
        : PocketVoiceFallbackReason.pocketSynthesisFailed;
    final remaining = response.remainingTextChunks.isNotEmpty
        ? response.remainingTextChunks
        : (!_playbackActive && _audio.isEmpty && _activeRequest != null)
        ? [_activeRequest!.text]
        : const <String>[];
    for (final text in remaining.reversed) {
      _utterances.addFirst(_SpeechRequest(text, systemOnly: true));
    }
    _synthesisComplete = true;
    state = PocketVoiceState(
      phase: _playbackActive || _audio.isNotEmpty
          ? PocketVoicePhase.speaking
          : PocketVoicePhase.synthesizing,
      backend: PocketVoiceBackend.pocket,
      fallbackReason: fallbackReason,
      conversationKey: state.conversationKey,
    );
    unawaited(_parkWorker());
    if (!_playbackActive && _audio.isEmpty) _finishUtterance();
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
        activeGeneration!,
      );
    } catch (error) {
      if (activeGeneration == _activeGeneration && state.enabled) {
        _failAll(
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
    switch (event.type) {
      case VoiceAudioEventType.started:
        if (!_matchesActiveEvent(event) || !_playbackActive || !state.enabled) {
          return;
        }
        state = PocketVoiceState(
          phase: PocketVoicePhase.speaking,
          backend: state.backend,
          fallbackReason: state.fallbackReason,
          conversationKey: state.conversationKey,
        );
      case VoiceAudioEventType.completed:
        if (!_matchesActiveEvent(event) || !_playbackActive) return;
        _playbackActive = false;
        if (_activeBackend == PocketVoiceBackend.pocket && _audio.isNotEmpty) {
          unawaited(_playNextChunk());
        } else if (_activeBackend == PocketVoiceBackend.androidSystem ||
            _synthesisComplete) {
          _finishUtterance();
        } else if (state.enabled) {
          state = PocketVoiceState(
            phase: PocketVoicePhase.synthesizing,
            backend: state.backend,
            fallbackReason: state.fallbackReason,
            conversationKey: state.conversationKey,
          );
        }
      case VoiceAudioEventType.error:
        if (_matchesActiveEvent(event) && _playbackActive) {
          _failAll(
            _activeBackend == PocketVoiceBackend.androidSystem
                ? 'Android system speech failed.'
                : 'Pocket voice playback failed.',
            failureKind: PocketVoiceFailureKind.playback,
          );
        }
      case VoiceAudioEventType.interrupted:
      case VoiceAudioEventType.routeLost:
      case VoiceAudioEventType.backgrounded:
        unawaited(interrupt());
      case VoiceAudioEventType.foregrounded:
        _pocketRetryAllowed = true;
        _startNextUtterance();
      case VoiceAudioEventType.resourcePressure:
        unawaited(_handleResourcePressure());
    }
  }

  bool _matchesActiveEvent(VoiceAudioEvent event) {
    final expectedBackend = switch (_activeBackend) {
      PocketVoiceBackend.pocket => VoiceAudioBackend.pocket,
      PocketVoiceBackend.androidSystem => VoiceAudioBackend.androidSystem,
      PocketVoiceBackend.none => null,
    };
    return event.backend == expectedBackend &&
        event.generation == _activeGeneration;
  }

  Future<void> _handleResourcePressure() async {
    _pocketRetryAllowed = false;
    if (_activeBackend == PocketVoiceBackend.pocket &&
        _activeGeneration != null) {
      _worker?.cancel();
      state = PocketVoiceState(
        phase: state.phase,
        backend: state.backend,
        fallbackReason: PocketVoiceFallbackReason.resourcePressure,
        conversationKey: state.conversationKey,
      );
      return;
    }
    await _parkWorker();
    if (state.enabled) {
      state = PocketVoiceState(
        phase: state.phase,
        backend: PocketVoiceBackend.androidSystem,
        fallbackReason: PocketVoiceFallbackReason.resourcePressure,
        conversationKey: state.conversationKey,
      );
      _startNextUtterance();
    }
  }

  void _failAll(String message, {required PocketVoiceFailureKind failureKind}) {
    _worker?.cancel();
    _utterances.clear();
    _activeRequest = null;
    _activeBackend = PocketVoiceBackend.none;
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
    _activeRequest = null;
    _activeBackend = PocketVoiceBackend.none;
    _activeGeneration = null;
    _synthesisComplete = false;
    _playbackActive = false;
    if (state.fallbackReason != null && !_pocketRetryAllowed) {
      state = PocketVoiceState(
        phase: PocketVoicePhase.listening,
        backend: PocketVoiceBackend.androidSystem,
        fallbackReason: state.fallbackReason,
        conversationKey: state.conversationKey,
      );
    }
    if (_utterances.isNotEmpty) {
      _startNextUtterance();
    } else if (state.enabled) {
      state = PocketVoiceState(
        phase: PocketVoicePhase.listening,
        backend: state.backend,
        fallbackReason: state.fallbackReason,
        conversationKey: state.conversationKey,
      );
    }
  }
}
