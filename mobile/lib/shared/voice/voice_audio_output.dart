import 'dart:async';

import 'package:flutter/services.dart';

enum VoiceAudioBackend { pocket, androidSystem }

enum VoiceAudioEventType {
  started,
  completed,
  interrupted,
  routeLost,
  backgrounded,
  foregrounded,
  resourcePressure,
  error,
}

class VoiceAudioEvent {
  final VoiceAudioEventType type;
  final VoiceAudioBackend? backend;
  final int? generation;

  const VoiceAudioEvent(this.type, {this.backend, this.generation});
}

abstract interface class VoiceAudioOutput {
  Stream<VoiceAudioEvent> get events;
  Future<bool> systemTtsAvailable();
  Future<void> play(Uint8List pcm, int sampleRate, int generation);
  Future<void> speakSystem(String text, int generation);
  Future<void> stop();
  Future<void> shutdownSystemTts();
}

class PlatformVoiceAudioOutput implements VoiceAudioOutput {
  static const _channel = MethodChannel('buzz/voice_audio');
  final StreamController<VoiceAudioEvent> _events =
      StreamController.broadcast();
  int? _legacyPocketGeneration;

  PlatformVoiceAudioOutput() {
    _channel.setMethodCallHandler((call) async {
      final arguments = call.arguments;
      final details = arguments is Map ? arguments : const <Object?, Object?>{};
      final reportedBackend = switch (details['backend']) {
        'pocket' => VoiceAudioBackend.pocket,
        'androidSystem' => VoiceAudioBackend.androidSystem,
        _ => null,
      };
      final backend =
          reportedBackend ??
          (_legacyPocketGeneration == null ? null : VoiceAudioBackend.pocket);
      final generation =
          details['generation'] as int? ?? _legacyPocketGeneration;
      final event = VoiceAudioEvent(
        switch (call.method) {
          'started' => VoiceAudioEventType.started,
          'completed' => VoiceAudioEventType.completed,
          'interrupted' => VoiceAudioEventType.interrupted,
          'routeLost' => VoiceAudioEventType.routeLost,
          'backgrounded' => VoiceAudioEventType.backgrounded,
          'foregrounded' => VoiceAudioEventType.foregrounded,
          'resourcePressure' => VoiceAudioEventType.resourcePressure,
          _ => VoiceAudioEventType.error,
        },
        backend: backend,
        generation: generation,
      );
      if (backend == VoiceAudioBackend.pocket &&
          (event.type == VoiceAudioEventType.completed ||
              event.type == VoiceAudioEventType.error)) {
        _legacyPocketGeneration = null;
      }
      _events.add(event);
    });
  }

  @override
  Stream<VoiceAudioEvent> get events => _events.stream;

  @override
  Future<bool> systemTtsAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('systemTtsAvailable') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> play(Uint8List pcm, int sampleRate, int generation) async {
    _legacyPocketGeneration = generation;
    try {
      await _channel.invokeMethod('play', {
        'pcm': pcm,
        'sampleRate': sampleRate,
        'generation': generation,
      });
    } catch (_) {
      if (_legacyPocketGeneration == generation) {
        _legacyPocketGeneration = null;
      }
      rethrow;
    }
  }

  @override
  Future<void> speakSystem(String text, int generation) => _channel
      .invokeMethod('speakSystem', {'text': text, 'generation': generation});

  @override
  Future<void> stop() {
    _legacyPocketGeneration = null;
    return _channel.invokeMethod('stop');
  }

  @override
  Future<void> shutdownSystemTts() async {
    try {
      await _channel.invokeMethod<void>('shutdownSystemTts');
    } on MissingPluginException {
      return;
    }
  }
}
