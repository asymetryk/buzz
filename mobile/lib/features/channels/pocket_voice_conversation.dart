import '../../shared/relay/relay.dart';
import 'channel_management_provider.dart';

/// Selects newly-arrived bot messages for Pocket voice.
///
/// Membership is authoritative: messages are never spoken until the channel's
/// member list has resolved, and history present when the view opens is only
/// used to establish the deduplication baseline.
class PocketVoiceConversation {
  final Set<String> _seen = {};
  bool _initialized = false;

  List<NostrEvent> update({
    required List<NostrEvent> events,
    required List<ChannelMember>? members,
    required String? currentPubkey,
    String? threadHeadId,
  }) {
    final unseen = <NostrEvent>[];
    for (final event in events) {
      if (_seen.add(event.id)) unseen.add(event);
    }
    if (_seen.length > 1024) {
      final retained = events.reversed
          .take(512)
          .map((event) => event.id)
          .toSet();
      _seen
        ..clear()
        ..addAll(retained);
    }
    if (!_initialized) {
      _initialized = true;
      return const [];
    }
    if (members == null) return const [];

    final bots = {
      for (final member in members)
        if (member.isBot) member.pubkey.toLowerCase(),
    };
    final self = currentPubkey?.toLowerCase();
    return [
      for (final event in unseen)
        if ((event.kind == EventKind.streamMessage ||
                event.kind == EventKind.streamMessageV2) &&
            event.pubkey.toLowerCase() != self &&
            bots.contains(event.pubkey.toLowerCase()) &&
            event.content.trim().length > 1 &&
            !event.content.trimLeft().startsWith('[System]') &&
            _belongsToConversation(event, threadHeadId))
          event,
    ];
  }

  static bool _belongsToConversation(NostrEvent event, String? threadHeadId) {
    final parentId = event.threadReference.parentId;
    return threadHeadId == null ? parentId == null : parentId == threadHeadId;
  }
}
