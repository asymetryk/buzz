import 'dart:io';

import 'package:buzz/shared/voice/voice_audio_output.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS system speech completes and suppresses stopped callbacks', (
    tester,
  ) async {
    if (!Platform.isIOS) return;
    final output = PlatformVoiceAudioOutput();

    final completion = output.events.firstWhere(
      (event) =>
          event == VoiceAudioEvent.completed || event == VoiceAudioEvent.error,
    );
    await output.speakSystem('Buzz system voice fallback is active.');
    expect(
      await completion.timeout(const Duration(seconds: 20)),
      VoiceAudioEvent.completed,
    );

    final eventsAfterStop = <VoiceAudioEvent>[];
    final subscription = output.events
        .where(
          (event) =>
              event == VoiceAudioEvent.completed ||
              event == VoiceAudioEvent.error,
        )
        .listen(eventsAfterStop.add);
    addTearDown(subscription.cancel);
    await output.speakSystem(
      List.filled(100, 'This cancelled speech must not finish.').join(' '),
    );
    await output.stop();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(eventsAfterStop, isEmpty);
  });
}
