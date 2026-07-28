import 'package:buzz/features/channels/channel_management_provider.dart';
import 'package:buzz/features/channels/pocket_voice_conversation.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final bot = ChannelMember(
    pubkey: 'bot',
    role: 'bot',
    joinedAt: DateTime.utc(2026),
  );
  final person = ChannelMember(
    pubkey: 'person',
    role: 'member',
    joinedAt: DateTime.utc(2026),
  );

  test('baselines history, then selects only new authoritative bot text', () {
    final conversation = PocketVoiceConversation();
    expect(
      conversation.update(
        events: [_event('history', 'bot', 'old')],
        members: [bot, person],
        currentPubkey: 'self',
      ),
      isEmpty,
    );

    final spoken = conversation.update(
      events: [
        _event('history', 'bot', 'old'),
        _event('person', 'person', 'hello'),
        _event('self', 'self', 'steer'),
        _event('system', 'bot', '[System] working'),
        _event('bot', 'bot', 'Assistant answer'),
      ],
      members: [bot, person],
      currentPubkey: 'self',
    );

    expect(spoken.map((event) => event.id), ['bot']);
  });

  test('fails closed while membership is unresolved', () {
    final conversation = PocketVoiceConversation();
    conversation.update(events: const [], members: null, currentPubkey: 'self');
    expect(
      conversation.update(
        events: [_event('bot', 'bot', 'answer')],
        members: null,
        currentPubkey: 'self',
      ),
      isEmpty,
    );
    expect(
      conversation.update(
        events: [_event('bot', 'bot', 'answer')],
        members: [bot],
        currentPubkey: 'self',
      ),
      isEmpty,
    );
  });

  test('thread conversation accepts only direct replies to its head', () {
    final conversation = PocketVoiceConversation();
    conversation.update(
      events: const [],
      members: [bot],
      currentPubkey: 'self',
      threadHeadId: 'root',
    );

    final spoken = conversation.update(
      events: [
        _event('top', 'bot', 'top level'),
        _event('direct', 'bot', 'direct', parent: 'root'),
        _event('nested', 'bot', 'nested', parent: 'other'),
      ],
      members: [bot],
      currentPubkey: 'self',
      threadHeadId: 'root',
    );

    expect(spoken.map((event) => event.id), ['direct']);
  });
}

NostrEvent _event(String id, String pubkey, String content, {String? parent}) =>
    NostrEvent(
      id: id,
      pubkey: pubkey,
      createdAt: 1,
      kind: EventKind.streamMessage,
      tags: [
        const ['h', 'channel'],
        if (parent != null) ['e', parent, '', 'reply'],
      ],
      content: content,
      sig: '',
    );
