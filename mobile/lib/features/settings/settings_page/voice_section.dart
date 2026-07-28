part of '../settings_page.dart';

class _VoiceSection extends ConsumerWidget {
  const _VoiceSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final model = ref.watch(pocketModelProvider);
    final downloading = model.phase == PocketModelPhase.downloading;
    final switching =
        downloading ||
        model.phase == PocketModelPhase.checking ||
        model.phase == PocketModelPhase.verifying;
    final status = switch (model.phase) {
      PocketModelPhase.checking => 'Checking…',
      PocketModelPhase.absent => 'Not downloaded',
      PocketModelPhase.downloading =>
        '${(model.progress * 100).clamp(0, 100).round()}%',
      PocketModelPhase.verifying => 'Verifying…',
      PocketModelPhase.ready => 'Ready',
      PocketModelPhase.cancelled => 'Cancelled',
      PocketModelPhase.insufficientSpace => 'Needs more space',
      PocketModelPhase.error => 'Download failed',
    };
    final action = switch (model.phase) {
      PocketModelPhase.ready ||
      PocketModelPhase.checking ||
      PocketModelPhase.verifying => null,
      PocketModelPhase.downloading =>
        () => ref.read(pocketModelProvider.notifier).cancel(),
      _ => () => ref.read(pocketModelProvider.notifier).download(),
    };

    return AppListCard(
      label: 'Voice',
      children: [
        AppListRow(
          icon: LucideIcons.gauge,
          title: 'Model size',
          subtitle: model.variant == PocketModelVariant.higherQuality
              ? 'Best voice quality. Uses more storage and memory.'
              : 'Smaller and faster. Uses the supported hybrid INT8 model.',
          subtitleMaxLines: 2,
          value: model.variant.label,
          trailing: switching ? null : const _RowChevron(),
          onTap: switching
              ? null
              : () => _showModelSizePicker(context, ref, model.variant),
        ),
        AppListRow(
          icon: LucideIcons.audioLines,
          title: 'Pocket voice',
          subtitle:
              model.message ??
              'Private, on-device speech. Downloads '
                  '${model.variant.runtimeBytes ~/ 1000000} MB after install.',
          subtitleMaxLines: 3,
          value: status,
          trailing: downloading
              ? SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    value: model.total == 0 ? null : model.progress,
                    strokeWidth: 2,
                  ),
                )
              : action == null
              ? null
              : Icon(
                  downloading ? LucideIcons.x : LucideIcons.download,
                  size: 18,
                  color: context.colors.primary,
                ),
          onTap: action,
        ),
        AppListRow(
          icon: LucideIcons.hardDriveDownload,
          title: 'Model storage',
          value: '${model.variant.runtimeBytes ~/ 1000000} MB',
          subtitle: 'Stored in application support, not duplicated in assets.',
          subtitleMaxLines: 2,
        ),
      ],
    );
  }
}

Future<void> _showModelSizePicker(
  BuildContext context,
  WidgetRef ref,
  PocketModelVariant selected,
) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (context) => SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final variant in PocketModelVariant.values)
          ListTile(
            leading: Icon(
              variant == selected
                  ? LucideIcons.circleCheck
                  : LucideIcons.circle,
            ),
            title: Text(variant.label),
            subtitle: Text(
              variant == PocketModelVariant.higherQuality
                  ? 'FP32 · ${variant.runtimeBytes ~/ 1000000} MB'
                  : 'Hybrid INT8 · ${variant.runtimeBytes ~/ 1000000} MB',
            ),
            onTap: () {
              Navigator.pop(context);
              unawaited(_selectPocketModelVariant(ref, variant));
            },
          ),
        const SizedBox(height: Grid.xs),
      ],
    ),
  ),
);

Future<void> _selectPocketModelVariant(
  WidgetRef ref,
  PocketModelVariant variant,
) async {
  if (variant == ref.read(pocketModelProvider).variant) return;
  await ref.read(pocketVoiceProvider.notifier).releaseEngineForModelSelection();
  await ref.read(pocketModelProvider.notifier).select(variant);
}
