import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:buzz/shared/relay/relay.dart';
import 'package:buzz/shared/voice/pocket_model_provider.dart';
import 'package:buzz/shared/voice/pocket_model_manifest.dart';
import 'package:buzz/shared/voice/pocket_voice_controller.dart';
import 'package:buzz/shared/voice/pocket_voice_worker.dart';
import 'package:buzz/shared/voice/voice_audio_output.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  test('queues assistant messages and plays every chunk in order', () async {
    final worker = _FakeWorker();
    final output = _FakeAudioOutput();
    final container = _container(worker, output);
    addTearDown(container.dispose);
    final notifier = container.read(pocketVoiceProvider.notifier);

    await notifier.enable('conversation');
    notifier.speak('conversation', 'First response.');
    notifier.speak('conversation', 'Second response.');

    expect(worker.syntheses, [(1, 'First response.')]);

    worker.emitAudio(1, [1, 2], isLast: false);
    await _flush();
    expect(output.played, hasLength(1));
    expect(output.played[0].$1, [1, 2]);
    expect(output.played[0].$2, 24000);
    expect(
      container.read(pocketVoiceProvider).phase,
      PocketVoicePhase.synthesizing,
    );
    output.started();
    await _flush();
    expect(
      container.read(pocketVoiceProvider).phase,
      PocketVoicePhase.speaking,
    );

    worker.emitAudio(1, [3, 4], isLast: true);
    await _flush();
    expect(output.played, hasLength(1));
    output.complete();
    await _flush();
    expect(output.played, hasLength(2));
    expect(output.played[1].$1, [3, 4]);
    expect(worker.syntheses, [(1, 'First response.')]);

    output.complete();
    await _flush();
    expect(worker.syntheses, [(1, 'First response.'), (2, 'Second response.')]);

    worker.emitAudio(2, [5, 6], isLast: true);
    await _flush();
    output.complete();
    await _flush();

    expect(output.played, hasLength(3));
    expect(output.played[0].$1, [1, 2]);
    expect(output.played[1].$1, [3, 4]);
    expect(output.played[2].$1, [5, 6]);
    expect(
      container.read(pocketVoiceProvider).phase,
      PocketVoicePhase.listening,
    );
  });

  test(
    'disable wins an overlapping engine startup and retains warm worker',
    () async {
      final worker = _FakeWorker(startPaused: true);
      final output = _FakeAudioOutput();
      final container = _container(worker, output);
      addTearDown(container.dispose);
      final notifier = container.read(pocketVoiceProvider.notifier);

      final enabling = notifier.enable('conversation');
      await _flush();
      final disabling = notifier.disable();
      worker.finishStart();
      await Future.wait([enabling, disabling]);

      expect(container.read(pocketVoiceProvider).phase, PocketVoicePhase.off);
      expect(worker.startCount, 1);
      expect(worker.disposeCount, 0);

      await notifier.enable('next-conversation');
      expect(worker.startCount, 1);
      expect(
        container.read(pocketVoiceProvider).phase,
        PocketVoicePhase.listening,
      );
    },
  );

  test('overlapping enables share an in-flight engine startup', () async {
    final worker = _FakeWorker(startPaused: true);
    final output = _FakeAudioOutput();
    final container = _container(worker, output);
    addTearDown(container.dispose);
    final notifier = container.read(pocketVoiceProvider.notifier);

    final first = notifier.enable('first-conversation');
    await _flush();
    final second = notifier.enable('second-conversation');
    await _flush();

    expect(worker.startCount, 1);
    expect(worker.disposeCount, 0);

    worker.finishStart();
    await Future.wait([first, second]);

    expect(worker.startCount, 1);
    expect(worker.disposeCount, 0);
    expect(
      container.read(pocketVoiceProvider).conversationKey,
      'second-conversation',
    );
    expect(
      container.read(pocketVoiceProvider).phase,
      PocketVoicePhase.listening,
    );
  });

  test('model selection releases the resident engine', () async {
    final worker = _FakeWorker();
    final output = _FakeAudioOutput();
    final container = _container(worker, output);
    addTearDown(container.dispose);
    final notifier = container.read(pocketVoiceProvider.notifier);

    await notifier.enable('conversation');
    await notifier.releaseEngineForModelSelection();

    expect(container.read(pocketVoiceProvider).phase, PocketVoicePhase.off);
    expect(worker.disposeCount, 1);
  });

  test(
    'model selection waits for an in-flight engine before release',
    () async {
      final worker = _FakeWorker(startPaused: true);
      final output = _FakeAudioOutput();
      final container = _container(worker, output);
      addTearDown(container.dispose);
      final notifier = container.read(pocketVoiceProvider.notifier);

      final enabling = notifier.enable('conversation');
      await _flush();
      final releasing = notifier.releaseEngineForModelSelection();
      await _flush();
      expect(worker.disposeCount, 0);

      worker.finishStart();
      await Future.wait([enabling, releasing]);

      expect(container.read(pocketVoiceProvider).phase, PocketVoicePhase.off);
      expect(worker.disposeCount, 1);
    },
  );

  test(
    'preserves text submitted while the resident engine is loading',
    () async {
      final worker = _FakeWorker(startPaused: true);
      final output = _FakeAudioOutput();
      final container = _container(worker, output);
      addTearDown(container.dispose);
      final notifier = container.read(pocketVoiceProvider.notifier);
      final longResponse = 'A' * 2100;

      final enabling = notifier.enable('conversation');
      await _flush();
      notifier.speak('conversation', longResponse);
      worker.finishStart();
      await enabling;

      expect(worker.syntheses, [(1, longResponse)]);
    },
  );

  test(
    'queues new responses during interrupt and rejects them during disable',
    () async {
      final worker = _FakeWorker();
      final output = _FakeAudioOutput();
      final container = _container(worker, output);
      addTearDown(container.dispose);
      final notifier = container.read(pocketVoiceProvider.notifier);

      await notifier.enable('conversation');
      notifier.speak('conversation', 'Before interrupt.');
      worker.pauseCancellation();
      final interrupting = notifier.interrupt();
      await _flush();
      notifier.speak('conversation', 'After steering.');
      expect(worker.syntheses, [(1, 'Before interrupt.')]);

      worker.finishCancellation();
      await interrupting;
      expect(worker.syntheses, [
        (1, 'Before interrupt.'),
        (2, 'After steering.'),
      ]);

      worker.pauseCancellation();
      final disabling = notifier.disable();
      notifier.speak('conversation', 'Must not be spoken.');
      worker.finishCancellation();
      await disabling;
      expect(worker.syntheses, hasLength(2));
      expect(container.read(pocketVoiceProvider).phase, PocketVoicePhase.off);
    },
  );

  test('surfaces asynchronous native playback errors', () async {
    final worker = _FakeWorker();
    final output = _FakeAudioOutput();
    final container = _container(worker, output);
    addTearDown(container.dispose);
    final notifier = container.read(pocketVoiceProvider.notifier);

    await notifier.enable('conversation');
    notifier.speak('conversation', 'Response.');
    worker.emitAudio(1, [1, 2], isLast: true);
    await _flush();
    output.fail();
    await _flush();

    final state = container.read(pocketVoiceProvider);
    expect(state.phase, PocketVoicePhase.error);
    expect(state.failureKind, PocketVoiceFailureKind.playback);
    expect(state.error, 'Pocket voice playback failed.');
    expect(worker.cancelCount, greaterThan(0));

    notifier.speak('conversation', 'Must wait for explicit recovery.');
    await _flush();
    expect(worker.syntheses, [(1, 'Response.')]);
    expect(container.read(pocketVoiceProvider), same(state));
  });

  test('classifies synthesis failures for platform fallback routing', () async {
    final worker = _FakeWorker();
    final output = _FakeAudioOutput();
    final container = _container(worker, output);
    addTearDown(container.dispose);
    final notifier = container.read(pocketVoiceProvider.notifier);

    await notifier.enable('conversation');
    notifier.speak('conversation', 'Response.');
    worker.emitFailure(
      1,
      PocketWorkerFailureKind.synthesis,
      'Pocket synthesis failed.',
    );
    await _flush();

    final state = container.read(pocketVoiceProvider);
    expect(state.phase, PocketVoicePhase.error);
    expect(state.failureKind, PocketVoiceFailureKind.synthesis);
    expect(state.error, 'Pocket synthesis failed.');
  });

  test('loads Faster through the existing worker precision seam', () async {
    final worker = _FakeWorker();
    final output = _FakeAudioOutput();
    final container = ProviderContainer(
      overrides: [
        relayConfigProvider.overrideWith(_TestRelayConfigNotifier.new),
        pocketModelProvider.overrideWith(_ReadyFasterModelNotifier.new),
        pocketVoiceWorkerFactoryProvider.overrideWithValue(() => worker),
        voiceAudioOutputProvider.overrideWithValue(output),
      ],
    );
    addTearDown(container.dispose);

    await container.read(pocketVoiceProvider.notifier).enable('conversation');

    expect(worker.startedPrecision, PocketModelVariant.faster.nativePrecision);
  });
}

ProviderContainer _container(_FakeWorker worker, _FakeAudioOutput output) =>
    ProviderContainer(
      overrides: [
        relayConfigProvider.overrideWith(_TestRelayConfigNotifier.new),
        pocketModelProvider.overrideWith(_ReadyPocketModelNotifier.new),
        pocketVoiceWorkerFactoryProvider.overrideWithValue(() => worker),
        voiceAudioOutputProvider.overrideWithValue(output),
      ],
    );

Future<void> _flush() => Future<void>.delayed(Duration.zero);

class _ReadyPocketModelNotifier extends PocketModelNotifier {
  @override
  PocketModelState build() => const PocketModelState(
    phase: PocketModelPhase.ready,
    path: '/tmp/pocket-model',
  );
}

class _ReadyFasterModelNotifier extends PocketModelNotifier {
  @override
  PocketModelState build() => const PocketModelState(
    phase: PocketModelPhase.ready,
    variant: PocketModelVariant.faster,
    path: '/tmp/pocket-model-int8',
  );
}

class _TestRelayConfigNotifier extends RelayConfigNotifier {
  @override
  RelayConfig build() => const RelayConfig(baseUrl: 'http://localhost:3000');
}

class _FakeWorker extends PocketVoiceWorker {
  final StreamController<PocketWorkerResponse> _controller =
      StreamController.broadcast();
  final Completer<void>? _startGate;
  final List<(int, String)> syntheses = [];
  Completer<void>? _cancelGate;
  bool _ready = false;
  int startCount = 0;
  int disposeCount = 0;
  int cancelCount = 0;
  int? startedPrecision;

  _FakeWorker({bool startPaused = false})
    : _startGate = startPaused ? Completer<void>() : null;

  @override
  Stream<PocketWorkerResponse> get responses => _controller.stream;

  @override
  bool get isReady => _ready;

  @override
  Future<void> start(String modelPath, {int precision = 0}) async {
    startCount += 1;
    startedPrecision = precision;
    await _startGate?.future;
    _ready = true;
  }

  void finishStart() => _startGate?.complete();

  @override
  void synthesize(int generation, String text) {
    syntheses.add((generation, text));
  }

  void emitAudio(int generation, List<int> bytes, {required bool isLast}) {
    _controller.add(
      PocketWorkerAudio(
        generation: generation,
        data: TransferableTypedData.fromList([Uint8List.fromList(bytes)]),
        sampleRate: 24000,
        synthesisTime: const Duration(milliseconds: 1),
        isLast: isLast,
      ),
    );
  }

  void emitFailure(
    int generation,
    PocketWorkerFailureKind kind,
    String message,
  ) {
    _controller.add(PocketWorkerFailure(kind, message, generation: generation));
  }

  @override
  void cancel() {
    cancelCount += 1;
  }

  @override
  Future<void> cancelAndWait() async {
    await _cancelGate?.future;
    _cancelGate = null;
  }

  void pauseCancellation() => _cancelGate = Completer<void>();

  void finishCancellation() => _cancelGate?.complete();

  @override
  Future<void> dispose() async {
    disposeCount += 1;
    await _controller.close();
  }
}

class _FakeAudioOutput implements VoiceAudioOutput {
  final StreamController<VoiceAudioEvent> _controller =
      StreamController.broadcast();
  final List<(List<int>, int)> played = [];

  @override
  Stream<VoiceAudioEvent> get events => _controller.stream;

  @override
  Future<void> play(Uint8List pcm, int sampleRate) async {
    played.add((pcm.toList(), sampleRate));
  }

  void complete() => _controller.add(VoiceAudioEvent.completed);

  void started() => _controller.add(VoiceAudioEvent.started);

  void fail() => _controller.add(VoiceAudioEvent.error);

  @override
  Future<void> stop() async {}
}
