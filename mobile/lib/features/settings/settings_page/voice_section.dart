part of '../settings_page.dart';

class _VoiceSection extends ConsumerWidget {
  const _VoiceSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final model = ref.watch(pocketModelProvider);
    final downloading = model.phase == PocketModelPhase.downloading;
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
          icon: LucideIcons.audioLines,
          title: 'Pocket voice',
          subtitle:
              model.message ??
              'Private, on-device speech. Downloads 473 MB after install.',
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
        const AppListRow(
          icon: LucideIcons.hardDriveDownload,
          title: 'Model storage',
          value: '${pocketModelRuntimeBytes ~/ 1000000} MB',
          subtitle: 'Stored in application support, not duplicated in assets.',
          subtitleMaxLines: 2,
        ),
      ],
    );
  }
}
