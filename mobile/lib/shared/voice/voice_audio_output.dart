import 'dart:async';

import 'package:flutter/services.dart';

enum VoiceAudioEvent {
  started,
  completed,
  interrupted,
  routeLost,
  backgrounded,
  foregrounded,
  resourcePressure,
  error,
}

abstract interface class VoiceAudioOutput {
  Stream<VoiceAudioEvent> get events;
  Future<void> play(Uint8List pcm, int sampleRate);
  Future<void> speakSystem(String text);
  Future<void> stop();
}

class PlatformVoiceAudioOutput implements VoiceAudioOutput {
  static const _channel = MethodChannel('buzz/voice_audio');
  final StreamController<VoiceAudioEvent> _events =
      StreamController.broadcast();

  PlatformVoiceAudioOutput() {
    _channel.setMethodCallHandler((call) async {
      final event = switch (call.method) {
        'started' => VoiceAudioEvent.started,
        'completed' => VoiceAudioEvent.completed,
        'interrupted' => VoiceAudioEvent.interrupted,
        'routeLost' => VoiceAudioEvent.routeLost,
        'backgrounded' => VoiceAudioEvent.backgrounded,
        'foregrounded' => VoiceAudioEvent.foregrounded,
        'resourcePressure' => VoiceAudioEvent.resourcePressure,
        _ => VoiceAudioEvent.error,
      };
      _events.add(event);
    });
  }

  @override
  Stream<VoiceAudioEvent> get events => _events.stream;

  @override
  Future<void> play(Uint8List pcm, int sampleRate) =>
      _channel.invokeMethod('play', {'pcm': pcm, 'sampleRate': sampleRate});

  @override
  Future<void> speakSystem(String text) =>
      _channel.invokeMethod('speakSystem', text);

  @override
  Future<void> stop() => _channel.invokeMethod('stop');
}
