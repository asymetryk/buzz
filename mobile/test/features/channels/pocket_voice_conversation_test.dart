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

  test('speaks new stream-message v2 bot replies', () {
    final conversation = PocketVoiceConversation();
    conversation.update(
      events: const [],
      members: [bot],
      currentPubkey: 'self',
    );

    final spoken = conversation.update(
      events: [
        _event(
          'v2',
          'bot',
          'Assistant answer',
          kind: EventKind.streamMessageV2,
        ),
      ],
      members: [bot],
      currentPubkey: 'self',
    );

    expect(spoken.map((event) => event.id), ['v2']);
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

  test('never re-speaks retained history after large conversation updates', () {
    final conversation = PocketVoiceConversation();
    final history = [
      for (var index = 0; index < 1100; index += 1)
        _event('history-$index', 'bot', 'Historical response $index'),
    ];
    conversation.update(events: history, members: [bot], currentPubkey: 'self');

    final spoken = conversation.update(
      events: [...history, _event('new', 'bot', 'New response')],
      members: [bot],
      currentPubkey: 'self',
    );

    expect(spoken.map((event) => event.id), ['new']);
  });
}

NostrEvent _event(
  String id,
  String pubkey,
  String content, {
  String? parent,
  int kind = EventKind.streamMessage,
}) => NostrEvent(
  id: id,
  pubkey: pubkey,
  createdAt: 1,
  kind: kind,
  tags: [
    const ['h', 'channel'],
    if (parent != null) ['e', parent, '', 'reply'],
  ],
  content: content,
  sig: '',
);
