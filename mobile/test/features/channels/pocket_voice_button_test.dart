import 'dart:async';
import 'dart:typed_data';

import 'package:buzz/features/channels/pocket_voice_button.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:buzz/shared/voice/pocket_model_provider.dart';
import 'package:buzz/shared/voice/pocket_voice_controller.dart';
import 'package:buzz/shared/voice/voice_audio_output.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  testWidgets('starts iOS system voice without a Pocket download', (
    tester,
  ) async {
    final output = _FakeAudioOutput();
    final container = ProviderContainer(
      overrides: [
        relayConfigProvider.overrideWith(_TestRelayConfigNotifier.new),
        pocketModelProvider.overrideWith(_AbsentPocketModelNotifier.new),
        voiceAudioOutputProvider.overrideWithValue(output),
        systemVoiceFallbackAvailableProvider.overrideWithValue(true),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: PocketVoiceButton(conversationKey: 'conversation'),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(IconButton));
    await tester.pump();

    final state = container.read(pocketVoiceProvider);
    expect(state.enabled, isTrue);
    expect(state.backend, VoiceBackend.system);
    expect(state.fallbackReason, VoiceFallbackReason.modelUnavailable);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byTooltip('Stop voice'), findsOneWidget);
  });
}

class _AbsentPocketModelNotifier extends PocketModelNotifier {
  @override
  PocketModelState build() =>
      const PocketModelState(phase: PocketModelPhase.absent);
}

class _TestRelayConfigNotifier extends RelayConfigNotifier {
  @override
  RelayConfig build() => const RelayConfig(baseUrl: 'http://localhost:3000');
}

class _FakeAudioOutput implements VoiceAudioOutput {
  final StreamController<VoiceAudioEvent> _events =
      StreamController.broadcast();

  @override
  Stream<VoiceAudioEvent> get events => _events.stream;

  @override
  Future<void> play(Uint8List pcm, int sampleRate) async {}

  @override
  Future<void> speakSystem(String text) async {}

  @override
  Future<void> stop() async {}
}
