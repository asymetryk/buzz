import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../shared/theme/theme.dart';
import '../../shared/voice/pocket_model_provider.dart';
import '../../shared/voice/pocket_voice_controller.dart';

class PocketVoiceButton extends ConsumerWidget {
  const PocketVoiceButton({super.key, required this.conversationKey});

  final String conversationKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final voice = ref.watch(pocketVoiceProvider);
    final model = ref.watch(pocketModelProvider);
    final active = voice.enabled && voice.conversationKey == conversationKey;

    return IconButton(
      color: active ? context.colors.primary : null,
      tooltip: active ? 'Stop voice' : 'Start voice',
      onPressed: () async {
        if (active) {
          await ref.read(pocketVoiceProvider.notifier).disable();
          return;
        }
        if (model.phase != PocketModelPhase.ready &&
            !ref.read(systemVoiceFallbackAvailableProvider)) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Download Pocket voice in Settings first.'),
              ),
            );
          }
          return;
        }
        try {
          await ref.read(pocketVoiceProvider.notifier).enable(conversationKey);
        } catch (error) {
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(error.toString())));
          }
        }
      },
      icon: voice.phase == PocketVoicePhase.loading && active
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(LucideIcons.audioLines, size: 21),
    );
  }
}
