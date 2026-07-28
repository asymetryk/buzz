import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../relay/relay.dart';
import 'pocket_model_provider.dart';
import 'pocket_voice_worker.dart';
import 'voice_audio_output.dart';

enum PocketVoicePhase { off, loading, listening, synthesizing, speaking, error }

enum PocketVoiceFailureKind { load, synthesis, playback }

enum VoiceBackend { none, pocket, system }

enum VoiceFallbackReason {
  modelUnavailable,
  loadFailure,
  synthesisFailure,
  resourcePressure,
}

@immutable
class PocketVoiceState {
  final PocketVoicePhase phase;
  final String? conversationKey;
  final PocketVoiceFailureKind? failureKind;
  final String? error;
  final VoiceBackend backend;
  final VoiceFallbackReason? fallbackReason;

  const PocketVoiceState({
    this.phase = PocketVoicePhase.off,
    this.conversationKey,
    this.failureKind,
    this.error,
    this.backend = VoiceBackend.none,
    this.fallbackReason,
  });

  bool get enabled => phase != PocketVoicePhase.off;
}

final voiceAudioOutputProvider = Provider<VoiceAudioOutput>(
  (_) => PlatformVoiceAudioOutput(),
);

final systemVoiceFallbackAvailableProvider = Provider<bool>(
  (_) => Platform.isIOS,
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
  Future<void>? _workerRetirement;
  StreamSubscription<PocketWorkerResponse>? _workerSubscription;
  StreamSubscription<VoiceAudioEvent>? _audioSubscription;
  int _transitionEpoch = 0;
  int _nextGeneration = 0;
  int? _activeGeneration;
  bool _synthesisComplete = false;
  bool _playbackActive = false;
  VoiceBackend _playbackBackend = VoiceBackend.none;
  String? _pendingSystemText;
  VoiceFallbackReason? _pendingFallbackReason;
  bool _pocketSuppressed = false;
  VoiceFallbackReason? _pocketSuppressionReason;
  bool _stopping = false;
  bool _queueWhileStopping = false;
  Future<void>? _stopFuture;

  bool get _systemFallbackAvailable =>
      ref.read(systemVoiceFallbackAvailableProvider);

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

    _pocketSuppressed = false;
    _pocketSuppressionReason = null;
    final model = ref.read(pocketModelProvider);
    if (model.phase != PocketModelPhase.ready || model.path == null) {
      if (!_systemFallbackAvailable) {
        throw StateError(
          'Download Pocket voice before starting a conversation.',
        );
      }
      state = PocketVoiceState(
        phase: PocketVoicePhase.listening,
        conversationKey: conversationKey,
        backend: VoiceBackend.system,
        fallbackReason: VoiceFallbackReason.modelUnavailable,
      );
      return;
    }

    state = PocketVoiceState(
      phase: PocketVoicePhase.loading,
      conversationKey: conversationKey,
      backend: VoiceBackend.pocket,
    );
    try {
      await _ensureWorker(model.path!);
      if (epoch != _transitionEpoch) return;
      if (_pocketSuppressed && _systemFallbackAvailable) {
        state = PocketVoiceState(
          phase: PocketVoicePhase.listening,
          conversationKey: conversationKey,
          backend: VoiceBackend.system,
          fallbackReason: _pocketSuppressionReason,
        );
        _retirePocketWorker();
        return;
      }
      state = PocketVoiceState(
        phase: PocketVoicePhase.listening,
        conversationKey: conversationKey,
        backend: VoiceBackend.pocket,
      );
      _startNextUtterance();
    } catch (error) {
      if (epoch != _transitionEpoch) return;
      if (_systemFallbackAvailable) {
        _suppressPocket(VoiceFallbackReason.loadFailure);
        state = PocketVoiceState(
          phase: PocketVoicePhase.listening,
          conversationKey: conversationKey,
          backend: VoiceBackend.system,
          fallbackReason: VoiceFallbackReason.loadFailure,
        );
        _startNextUtterance();
        return;
      }
      state = PocketVoiceState(
        phase: PocketVoicePhase.error,
        conversationKey: conversationKey,
        failureKind: PocketVoiceFailureKind.load,
        error: error.toString(),
      );
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
        backend: _idleBackend(),
        fallbackReason: _idleFallbackReason(),
      );
      _startNextUtterance();
    }
  }

  Future<PocketVoiceWorker> _ensureWorker(String modelPath) async {
    await _workerRetirement;
    final worker = _worker;
    if (worker != null && worker.isReady) return worker;
    final starting = _workerStart;
    if (starting != null) return starting;

    final created = ref.read(pocketVoiceWorkerFactoryProvider)();
    _worker = created;
    _workerSubscription = created.responses.listen(_handleWorkerResponse);
    final future = created.start(modelPath).then((_) => created);
    _workerStart = future;
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
    _pendingSystemText = null;
    _pendingFallbackReason = null;
    _activeGeneration = null;
    _synthesisComplete = false;
    _playbackActive = false;
    _playbackBackend = VoiceBackend.none;
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
        !state.enabled ||
        state.phase == PocketVoicePhase.loading) {
      return;
    }
    final utterance = _utterances.removeFirst();
    final generation = ++_nextGeneration;
    _activeGeneration = generation;
    _synthesisComplete = false;
    _pendingSystemText = null;
    _pendingFallbackReason = null;

    final model = ref.read(pocketModelProvider);
    if (!_pocketSuppressed &&
        model.phase == PocketModelPhase.ready &&
        model.path != null) {
      final worker = _worker;
      if (worker != null && worker.isReady && _workerRetirement == null) {
        _beginPocket(generation, utterance, worker);
      } else {
        state = PocketVoiceState(
          phase: PocketVoicePhase.loading,
          conversationKey: state.conversationKey,
          backend: VoiceBackend.pocket,
        );
        unawaited(_loadPocketAndBegin(generation, utterance, model.path!));
      }
      return;
    }
    _beginSystem(
      generation,
      utterance,
      _pocketSuppressionReason ?? VoiceFallbackReason.modelUnavailable,
    );
  }

  Future<void> _loadPocketAndBegin(
    int generation,
    String utterance,
    String modelPath,
  ) async {
    try {
      final worker = await _ensureWorker(modelPath);
      if (generation != _activeGeneration || !state.enabled) return;
      if (_pocketSuppressed && _systemFallbackAvailable) {
        _retirePocketWorker();
        _beginSystem(
          generation,
          utterance,
          _pocketSuppressionReason ?? VoiceFallbackReason.resourcePressure,
        );
        return;
      }
      _beginPocket(generation, utterance, worker);
    } catch (error) {
      if (generation != _activeGeneration || !state.enabled) return;
      if (_systemFallbackAvailable) {
        _suppressPocket(VoiceFallbackReason.loadFailure);
        _beginSystem(generation, utterance, VoiceFallbackReason.loadFailure);
      } else {
        _failPlayback(
          error.toString(),
          failureKind: PocketVoiceFailureKind.load,
        );
      }
    }
  }

  void _beginPocket(
    int generation,
    String utterance,
    PocketVoiceWorker worker,
  ) {
    if (generation != _activeGeneration || !state.enabled) return;
    state = PocketVoiceState(
      phase: PocketVoicePhase.synthesizing,
      conversationKey: state.conversationKey,
      backend: VoiceBackend.pocket,
    );
    try {
      worker.synthesize(generation, utterance);
    } catch (error) {
      _handlePocketFailure(
        PocketWorkerFailure(
          PocketWorkerFailureKind.synthesis,
          error.toString(),
          generation: generation,
          remainingText: utterance,
        ),
      );
    }
  }

  void _beginSystem(int generation, String text, VoiceFallbackReason reason) {
    if (generation != _activeGeneration || !state.enabled) return;
    if (!_systemFallbackAvailable) {
      _failPlayback(
        'System speech is unavailable.',
        failureKind: PocketVoiceFailureKind.playback,
      );
      return;
    }
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      _finishUtterance();
      return;
    }
    _pendingSystemText = null;
    _pendingFallbackReason = null;
    _playbackActive = true;
    _playbackBackend = VoiceBackend.system;
    state = PocketVoiceState(
      phase: PocketVoicePhase.speaking,
      conversationKey: state.conversationKey,
      backend: VoiceBackend.system,
      fallbackReason: reason,
    );
    ref.read(voiceAudioOutputProvider).speakSystem(trimmed).catchError((
      Object error,
    ) {
      if (generation == _activeGeneration &&
          _playbackBackend == VoiceBackend.system &&
          state.enabled) {
        _failPlayback(
          error.toString(),
          failureKind: PocketVoiceFailureKind.playback,
        );
      }
    });
  }

  void _handleWorkerResponse(PocketWorkerResponse response) {
    switch (response) {
      case PocketWorkerReady():
      case PocketWorkerStopped():
        return;
      case PocketWorkerDone():
        if (response.generation != _activeGeneration) return;
        _synthesisComplete = true;
        _playNextOutput();
      case PocketWorkerFailure():
        _handlePocketFailure(response);
      case PocketWorkerAudio():
        if (response.generation != _activeGeneration) return;
        _audio.add(response);
        if (response.isLast) _synthesisComplete = true;
        _playNextOutput();
    }
  }

  void _handlePocketFailure(PocketWorkerFailure response) {
    if (response.generation != _activeGeneration) return;
    if (response.kind == PocketWorkerFailureKind.cancelled &&
        _pocketSuppressionReason != VoiceFallbackReason.resourcePressure) {
      _finishUtterance();
      return;
    }
    if (!_systemFallbackAvailable) {
      _failPlayback(
        response.message,
        failureKind: PocketVoiceFailureKind.synthesis,
      );
      return;
    }
    final reason =
        _pocketSuppressionReason == VoiceFallbackReason.resourcePressure
        ? VoiceFallbackReason.resourcePressure
        : VoiceFallbackReason.synthesisFailure;
    _suppressPocket(reason);
    _synthesisComplete = true;
    final remaining = response.remainingText?.trim();
    if (remaining != null && remaining.isNotEmpty) {
      _pendingSystemText = remaining;
      _pendingFallbackReason = reason;
    }
    _retirePocketWorker();
    _playNextOutput();
  }

  void _playNextOutput() {
    if (_playbackActive || _activeGeneration == null) return;
    if (_audio.isNotEmpty) {
      unawaited(_playNextChunk());
      return;
    }
    final pendingSystemText = _pendingSystemText;
    if (pendingSystemText != null) {
      _beginSystem(
        _activeGeneration!,
        pendingSystemText,
        _pendingFallbackReason ?? VoiceFallbackReason.synthesisFailure,
      );
      return;
    }
    if (_synthesisComplete) _finishUtterance();
  }

  Future<void> _playNextChunk() async {
    if (_playbackActive || _audio.isEmpty || _activeGeneration == null) return;
    final activeGeneration = _activeGeneration;
    final conversationKey = state.conversationKey;
    final chunk = _audio.removeFirst();
    _playbackActive = true;
    _playbackBackend = VoiceBackend.pocket;
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
      _playbackBackend = VoiceBackend.none;
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
          backend: _playbackBackend,
          fallbackReason: _playbackBackend == VoiceBackend.system
              ? state.fallbackReason
              : null,
        );
      case VoiceAudioEvent.completed:
        if (!_playbackActive) return;
        final completedBackend = _playbackBackend;
        _playbackActive = false;
        _playbackBackend = VoiceBackend.none;
        if (completedBackend == VoiceBackend.system) {
          _finishUtterance();
        } else {
          _playNextOutput();
        }
      case VoiceAudioEvent.error:
        if (_playbackActive) {
          _failPlayback(
            _playbackBackend == VoiceBackend.pocket
                ? 'Pocket voice playback failed.'
                : 'System voice playback failed.',
            failureKind: PocketVoiceFailureKind.playback,
          );
        }
      case VoiceAudioEvent.interrupted:
      case VoiceAudioEvent.routeLost:
      case VoiceAudioEvent.backgrounded:
        unawaited(interrupt());
      case VoiceAudioEvent.foregrounded:
        _pocketSuppressed = false;
        _pocketSuppressionReason = null;
      case VoiceAudioEvent.resourcePressure:
        _handleResourcePressure();
    }
  }

  void _handleResourcePressure() {
    if (!_systemFallbackAvailable) return;
    _suppressPocket(VoiceFallbackReason.resourcePressure);
    final worker = _worker;
    if (worker != null) {
      worker.cancel();
      _retirePocketWorker();
    }
    if (_activeGeneration == null && state.enabled) {
      state = PocketVoiceState(
        phase: PocketVoicePhase.listening,
        conversationKey: state.conversationKey,
        backend: VoiceBackend.system,
        fallbackReason: VoiceFallbackReason.resourcePressure,
      );
    }
  }

  void _suppressPocket(VoiceFallbackReason reason) {
    _pocketSuppressed = true;
    _pocketSuppressionReason = reason;
  }

  void _retirePocketWorker() {
    if (_workerRetirement != null) return;
    final worker = _worker;
    if (worker == null) return;
    final retirement = () async {
      final starting = _workerStart;
      if (starting != null) {
        try {
          await starting;
        } catch (_) {
          return;
        }
      }
      if (!identical(_worker, worker)) return;
      worker.cancel();
      await worker.cancelAndWait();
      if (identical(_worker, worker)) {
        _worker = null;
        await _workerSubscription?.cancel();
        _workerSubscription = null;
      }
      await worker.dispose();
    }();
    _workerRetirement = retirement;
    unawaited(
      retirement.whenComplete(() {
        if (identical(_workerRetirement, retirement)) {
          _workerRetirement = null;
        }
      }),
    );
  }

  void _failPlayback(
    String message, {
    required PocketVoiceFailureKind failureKind,
  }) {
    _worker?.cancel();
    _utterances.clear();
    _activeGeneration = null;
    _audio.clear();
    _pendingSystemText = null;
    _pendingFallbackReason = null;
    _synthesisComplete = false;
    _playbackActive = false;
    _playbackBackend = VoiceBackend.none;
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
    _pendingSystemText = null;
    _pendingFallbackReason = null;
    _synthesisComplete = false;
    _playbackActive = false;
    _playbackBackend = VoiceBackend.none;
    if (_utterances.isNotEmpty) {
      _startNextUtterance();
    } else if (state.enabled) {
      state = PocketVoiceState(
        phase: PocketVoicePhase.listening,
        conversationKey: state.conversationKey,
        backend: _idleBackend(),
        fallbackReason: _idleFallbackReason(),
      );
    }
  }

  VoiceBackend _idleBackend() {
    if (_pocketSuppressed) return VoiceBackend.system;
    final model = ref.read(pocketModelProvider);
    return model.phase == PocketModelPhase.ready
        ? VoiceBackend.pocket
        : VoiceBackend.system;
  }

  VoiceFallbackReason? _idleFallbackReason() {
    if (_pocketSuppressed) return _pocketSuppressionReason;
    final model = ref.read(pocketModelProvider);
    return model.phase == PocketModelPhase.ready
        ? null
        : VoiceFallbackReason.modelUnavailable;
  }
}
