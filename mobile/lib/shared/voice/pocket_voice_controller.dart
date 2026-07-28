import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'pocket_model_provider.dart';
import 'pocket_voice_worker.dart';
import 'voice_audio_output.dart';
import '../relay/relay.dart';

enum PocketVoicePhase { off, loading, listening, synthesizing, speaking, error }

@immutable
class PocketVoiceState {
  final PocketVoicePhase phase;
  final String? conversationKey;
  final String? error;
  final Duration? synthesisTime;
  final Duration? timeToPlayback;
  final double? realTimeFactor;

  const PocketVoiceState({
    this.phase = PocketVoicePhase.off,
    this.conversationKey,
    this.error,
    this.synthesisTime,
    this.timeToPlayback,
    this.realTimeFactor,
  });

  bool get enabled => phase != PocketVoicePhase.off;
}

final voiceAudioOutputProvider = Provider<VoiceAudioOutput>(
  (_) => PlatformVoiceAudioOutput(),
);

final pocketVoiceProvider =
    NotifierProvider<PocketVoiceNotifier, PocketVoiceState>(
      PocketVoiceNotifier.new,
    );

class PocketVoiceNotifier extends Notifier<PocketVoiceState> {
  PocketVoiceWorker? _worker;
  StreamSubscription<PocketWorkerResponse>? _workerSubscription;
  StreamSubscription<VoiceAudioEvent>? _audioSubscription;
  int _generation = 0;
  Stopwatch? _playbackClock;

  @override
  PocketVoiceState build() {
    ref.listen(relayConfigProvider, (previous, _) {
      if (previous != null) unawaited(disable());
    });
    _audioSubscription = ref.read(voiceAudioOutputProvider).events.listen((
      event,
    ) {
      if (event != VoiceAudioEvent.completed) {
        unawaited(interrupt());
      } else if (state.enabled) {
        state = PocketVoiceState(
          phase: PocketVoicePhase.listening,
          conversationKey: state.conversationKey,
          synthesisTime: state.synthesisTime,
          timeToPlayback: state.timeToPlayback,
          realTimeFactor: state.realTimeFactor,
        );
      }
    });
    ref.onDispose(() {
      _workerSubscription?.cancel();
      _audioSubscription?.cancel();
      unawaited(_worker?.dispose());
    });
    return const PocketVoiceState();
  }

  Future<void> enable(String conversationKey) async {
    if (state.conversationKey == conversationKey && state.enabled) return;
    await disable();
    final model = ref.read(pocketModelProvider);
    if (model.phase != PocketModelPhase.ready || model.path == null) {
      throw StateError('Download Pocket voice before starting a conversation.');
    }
    state = PocketVoiceState(
      phase: PocketVoicePhase.loading,
      conversationKey: conversationKey,
    );
    final worker = PocketVoiceWorker();
    _worker = worker;
    _workerSubscription = worker.responses.listen(_handleWorkerResponse);
    try {
      await worker.start(model.path!);
      state = PocketVoiceState(
        phase: PocketVoicePhase.listening,
        conversationKey: conversationKey,
      );
    } catch (error) {
      state = PocketVoiceState(
        phase: PocketVoicePhase.error,
        conversationKey: conversationKey,
        error: error.toString(),
      );
      rethrow;
    }
  }

  Future<void> disable() async {
    _generation += 1;
    await ref.read(voiceAudioOutputProvider).stop();
    _worker?.cancel();
    await _workerSubscription?.cancel();
    _workerSubscription = null;
    await _worker?.dispose();
    _worker = null;
    state = const PocketVoiceState();
  }

  void speak(String conversationKey, String text) {
    if (!state.enabled || state.conversationKey != conversationKey) return;
    final trimmed = text.trim();
    if (trimmed.length <= 1 || trimmed.startsWith('[System]')) return;
    final bounded = String.fromCharCodes(trimmed.runes.take(2000));
    _generation += 1;
    _playbackClock = Stopwatch()..start();
    state = PocketVoiceState(
      phase: PocketVoicePhase.synthesizing,
      conversationKey: conversationKey,
    );
    _worker?.synthesize(_generation, bounded);
  }

  Future<void> interrupt() async {
    _generation += 1;
    _worker?.cancel();
    await ref.read(voiceAudioOutputProvider).stop();
    if (state.enabled) {
      state = PocketVoiceState(
        phase: PocketVoicePhase.listening,
        conversationKey: state.conversationKey,
      );
    }
  }

  Future<void> _handleWorkerResponse(PocketWorkerResponse response) async {
    switch (response) {
      case PocketWorkerReady():
        return;
      case PocketWorkerStopped():
        return;
      case PocketWorkerFailure():
        if (response.generation != null && response.generation != _generation) {
          return;
        }
        state = PocketVoiceState(
          phase: PocketVoicePhase.error,
          conversationKey: state.conversationKey,
          error: response.message,
        );
      case PocketWorkerAudio():
        if (response.generation != _generation) return;
        final bytes = response.data.materialize().asUint8List();
        final audioSeconds = bytes.length / 2 / response.sampleRate;
        final rtf = audioSeconds == 0
            ? null
            : response.synthesisTime.inMicroseconds /
                  Duration.microsecondsPerSecond /
                  audioSeconds;
        await ref
            .read(voiceAudioOutputProvider)
            .play(Uint8List.fromList(bytes), response.sampleRate);
        _playbackClock?.stop();
        state = PocketVoiceState(
          phase: PocketVoicePhase.speaking,
          conversationKey: state.conversationKey,
          synthesisTime: response.synthesisTime,
          timeToPlayback: _playbackClock?.elapsed,
          realTimeFactor: rtf,
        );
    }
  }
}
