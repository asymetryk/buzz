import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:buzz/shared/relay/relay.dart';
import 'package:buzz/shared/voice/pocket_model_provider.dart';
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
    'advances the queue after Pocket filters an utterance to empty',
    () async {
      final worker = _FakeWorker();
      final output = _FakeAudioOutput();
      final container = _container(worker, output);
      addTearDown(container.dispose);
      final notifier = container.read(pocketVoiceProvider.notifier);

      await notifier.enable('conversation');
      notifier.speak('conversation', '🤖🤖');
      notifier.speak('conversation', 'Spoken response.');
      worker.emitDone(1);
      await _flush();

      expect(worker.syntheses, [(1, '🤖🤖'), (2, 'Spoken response.')]);
      expect(container.read(pocketVoiceProvider).error, isNull);
    },
  );

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
      kind: PocketWorkerFailureKind.synthesis,
      message: 'Pocket synthesis failed.',
    );
    await _flush();

    final state = container.read(pocketVoiceProvider);
    expect(state.phase, PocketVoicePhase.error);
    expect(state.failureKind, PocketVoiceFailureKind.synthesis);
    expect(state.error, 'Pocket synthesis failed.');
  });

  test('uses system speech when the Pocket model is unavailable', () async {
    final worker = _FakeWorker();
    final output = _FakeAudioOutput();
    final container = _container(
      worker,
      output,
      fallbackAvailable: true,
      model: _AbsentPocketModelNotifier.new,
    );
    addTearDown(container.dispose);
    final notifier = container.read(pocketVoiceProvider.notifier);

    await notifier.enable('conversation');
    notifier.speak('conversation', 'System fallback response.');
    await _flush();

    expect(worker.startCount, 0);
    expect(output.systemSpeech, ['System fallback response.']);
    expect(
      container.read(pocketVoiceProvider),
      isA<PocketVoiceState>()
          .having((state) => state.backend, 'backend', VoiceBackend.system)
          .having(
            (state) => state.fallbackReason,
            'fallback reason',
            VoiceFallbackReason.modelUnavailable,
          )
          .having((state) => state.error, 'error', isNull),
    );
  });

  test('retains the Pocket download gate without an iOS fallback', () async {
    final worker = _FakeWorker();
    final output = _FakeAudioOutput();
    final container = _container(
      worker,
      output,
      model: _AbsentPocketModelNotifier.new,
    );
    addTearDown(container.dispose);

    await expectLater(
      container.read(pocketVoiceProvider.notifier).enable('conversation'),
      throwsA(isA<StateError>()),
    );

    expect(container.read(pocketVoiceProvider).phase, PocketVoicePhase.off);
    expect(worker.startCount, 0);
    expect(output.systemSpeech, isEmpty);
  });

  test(
    'falls back without an error when the Pocket engine fails to load',
    () async {
      final worker = _FakeWorker(startError: StateError('load failed'));
      final output = _FakeAudioOutput();
      final container = _container(worker, output, fallbackAvailable: true);
      addTearDown(container.dispose);
      final notifier = container.read(pocketVoiceProvider.notifier);

      await notifier.enable('conversation');
      notifier.speak('conversation', 'Recovered response.');
      await _flush();

      expect(output.systemSpeech, ['Recovered response.']);
      expect(
        container.read(pocketVoiceProvider).fallbackReason,
        VoiceFallbackReason.loadFailure,
      );
      expect(container.read(pocketVoiceProvider).error, isNull);
    },
  );

  test('falls back once to the unsynthesized Pocket remainder', () async {
    final worker = _FakeWorker();
    final output = _FakeAudioOutput();
    final container = _container(worker, output, fallbackAvailable: true);
    addTearDown(container.dispose);
    final notifier = container.read(pocketVoiceProvider.notifier);

    await notifier.enable('conversation');
    notifier.speak('conversation', 'Whole response.');
    worker.emitFailure(1, remainingText: 'Whole response.');
    await _flush();

    expect(output.systemSpeech, ['Whole response.']);
    expect(output.played, isEmpty);
    expect(
      container.read(pocketVoiceProvider).fallbackReason,
      VoiceFallbackReason.synthesisFailure,
    );
  });

  test(
    'drains Pocket audio before fallback and preserves queue order',
    () async {
      final worker = _FakeWorker();
      final output = _FakeAudioOutput();
      final container = _container(worker, output, fallbackAvailable: true);
      addTearDown(container.dispose);
      final notifier = container.read(pocketVoiceProvider.notifier);

      await notifier.enable('conversation');
      notifier.speak('conversation', 'First response.');
      notifier.speak('conversation', 'Second response.');
      worker.emitAudio(1, [1, 2], isLast: false);
      worker.emitFailure(1, remainingText: 'First remainder.');
      await _flush();

      expect(output.played, hasLength(1));
      expect(output.systemSpeech, isEmpty);

      output.complete();
      await _flush();
      expect(output.systemSpeech, ['First remainder.']);

      output.complete();
      await _flush();
      expect(output.systemSpeech, ['First remainder.', 'Second response.']);
      expect(worker.syntheses, [(1, 'First response.')]);
    },
  );

  test(
    'system speech keeps steering and disable cancellation semantics',
    () async {
      final worker = _FakeWorker();
      final output = _FakeAudioOutput();
      final container = _container(
        worker,
        output,
        fallbackAvailable: true,
        model: _AbsentPocketModelNotifier.new,
      );
      addTearDown(container.dispose);
      final notifier = container.read(pocketVoiceProvider.notifier);

      await notifier.enable('conversation');
      notifier.speak('conversation', 'Before steering.');
      output.pauseStop();
      final interrupting = notifier.interrupt();
      await _flush();
      notifier.speak('conversation', 'After steering.');
      output.finishStop();
      await interrupting;
      await _flush();

      expect(output.systemSpeech, ['Before steering.', 'After steering.']);

      output.pauseStop();
      final disabling = notifier.disable();
      notifier.speak('conversation', 'Must not be spoken.');
      output.finishStop();
      await disabling;
      expect(output.systemSpeech, ['Before steering.', 'After steering.']);
      expect(container.read(pocketVoiceProvider).phase, PocketVoicePhase.off);
    },
  );

  test(
    'resource pressure uses system speech then recovers Pocket on foreground',
    () async {
      final firstWorker = _FakeWorker();
      final recoveredWorker = _FakeWorker();
      final workers = Queue.of([firstWorker, recoveredWorker]);
      final output = _FakeAudioOutput();
      final container = _container(
        firstWorker,
        output,
        fallbackAvailable: true,
        workerFactory: () => workers.removeFirst(),
      );
      addTearDown(container.dispose);
      final notifier = container.read(pocketVoiceProvider.notifier);

      await notifier.enable('conversation');
      output.emit(VoiceAudioEvent.resourcePressure);
      for (var i = 0; i < 10 && firstWorker.disposeCount == 0; i += 1) {
        await _flush();
      }
      notifier.speak('conversation', 'During pressure.');
      await _flush();

      expect(output.systemSpeech, ['During pressure.']);
      expect(
        container.read(pocketVoiceProvider).fallbackReason,
        VoiceFallbackReason.resourcePressure,
      );

      output.complete();
      await _flush();
      output.emit(VoiceAudioEvent.foregrounded);
      await _flush();
      notifier.speak('conversation', 'Pocket recovered.');
      for (var i = 0; i < 10 && recoveredWorker.syntheses.isEmpty; i += 1) {
        await _flush();
      }

      expect(recoveredWorker.syntheses, [(2, 'Pocket recovered.')]);
    },
  );

  test(
    'foreground recovery waits for the pressured worker to retire',
    () async {
      final firstWorker = _FakeWorker();
      final recoveredWorker = _FakeWorker();
      final workers = Queue.of([firstWorker, recoveredWorker]);
      final output = _FakeAudioOutput();
      final container = _container(
        firstWorker,
        output,
        fallbackAvailable: true,
        workerFactory: () => workers.removeFirst(),
      );
      addTearDown(container.dispose);
      final notifier = container.read(pocketVoiceProvider.notifier);

      await notifier.enable('conversation');
      firstWorker.pauseCancellation();
      output.emit(VoiceAudioEvent.resourcePressure);
      await _flush();
      output.emit(VoiceAudioEvent.foregrounded);
      await _flush();
      notifier.speak('conversation', 'Recovered after retirement.');
      await _flush();

      expect(firstWorker.syntheses, isEmpty);
      expect(recoveredWorker.syntheses, isEmpty);

      firstWorker.finishCancellation();
      for (var i = 0; i < 10 && recoveredWorker.syntheses.isEmpty; i += 1) {
        await _flush();
      }

      expect(recoveredWorker.syntheses, [(1, 'Recovered after retirement.')]);
    },
  );

  test(
    'resource pressure cancellation falls back to the unsynthesized text',
    () async {
      final worker = _FakeWorker();
      final output = _FakeAudioOutput();
      final container = _container(worker, output, fallbackAvailable: true);
      addTearDown(container.dispose);
      final notifier = container.read(pocketVoiceProvider.notifier);

      await notifier.enable('conversation');
      notifier.speak('conversation', 'Cancelled Pocket response.');
      worker.pauseCancellation();
      output.emit(VoiceAudioEvent.resourcePressure);
      await _flush();
      worker.emitFailure(
        1,
        kind: PocketWorkerFailureKind.cancelled,
        message: 'synthesis cancelled',
        remainingText: 'Cancelled Pocket response.',
      );
      await _flush();
      worker.finishCancellation();
      await _flush();

      expect(output.systemSpeech, ['Cancelled Pocket response.']);
      expect(
        container.read(pocketVoiceProvider).fallbackReason,
        VoiceFallbackReason.resourcePressure,
      );
      expect(container.read(pocketVoiceProvider).error, isNull);
    },
  );

  test(
    'resource pressure during load completes safely on system speech',
    () async {
      final worker = _FakeWorker(startPaused: true);
      final output = _FakeAudioOutput();
      final container = _container(worker, output, fallbackAvailable: true);
      addTearDown(container.dispose);
      final notifier = container.read(pocketVoiceProvider.notifier);

      final enabling = notifier.enable('conversation');
      await _flush();
      output.emit(VoiceAudioEvent.resourcePressure);
      await _flush();
      worker.finishStart();
      await enabling;

      expect(container.read(pocketVoiceProvider).backend, VoiceBackend.system);
      expect(
        container.read(pocketVoiceProvider).fallbackReason,
        VoiceFallbackReason.resourcePressure,
      );
      notifier.speak('conversation', 'Pressure fallback.');
      await _flush();
      expect(output.systemSpeech, ['Pressure fallback.']);
    },
  );
}

ProviderContainer _container(
  _FakeWorker worker,
  _FakeAudioOutput output, {
  bool fallbackAvailable = false,
  PocketModelNotifier Function() model = _ReadyPocketModelNotifier.new,
  PocketVoiceWorker Function()? workerFactory,
}) => ProviderContainer(
  overrides: [
    relayConfigProvider.overrideWith(_TestRelayConfigNotifier.new),
    pocketModelProvider.overrideWith(model),
    pocketVoiceWorkerFactoryProvider.overrideWithValue(
      workerFactory ?? () => worker,
    ),
    voiceAudioOutputProvider.overrideWithValue(output),
    systemVoiceFallbackAvailableProvider.overrideWithValue(fallbackAvailable),
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

class _AbsentPocketModelNotifier extends PocketModelNotifier {
  @override
  PocketModelState build() =>
      const PocketModelState(phase: PocketModelPhase.absent);
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
  final Object? startError;

  _FakeWorker({bool startPaused = false, this.startError})
    : _startGate = startPaused ? Completer<void>() : null;

  @override
  Stream<PocketWorkerResponse> get responses => _controller.stream;

  @override
  bool get isReady => _ready;

  @override
  Future<void> start(String modelPath) async {
    startCount += 1;
    await _startGate?.future;
    if (startError case final error?) throw error;
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
    int generation, {
    PocketWorkerFailureKind kind = PocketWorkerFailureKind.synthesis,
    String message = 'synthesis failed',
    String? remainingText,
  }) {
    _controller.add(
      PocketWorkerFailure(
        kind,
        message,
        generation: generation,
        remainingText: remainingText,
      ),
    );
  }

  void emitDone(int generation) {
    _controller.add(PocketWorkerDone(generation));
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
  final List<String> systemSpeech = [];
  Completer<void>? _stopGate;
  int stopCount = 0;

  @override
  Stream<VoiceAudioEvent> get events => _controller.stream;

  @override
  Future<void> play(Uint8List pcm, int sampleRate) async {
    played.add((pcm.toList(), sampleRate));
  }

  @override
  Future<void> speakSystem(String text) async {
    systemSpeech.add(text);
  }

  void complete() => _controller.add(VoiceAudioEvent.completed);

  void started() => _controller.add(VoiceAudioEvent.started);

  void fail() => _controller.add(VoiceAudioEvent.error);

  void emit(VoiceAudioEvent event) => _controller.add(event);

  void pauseStop() => _stopGate = Completer<void>();

  void finishStop() => _stopGate?.complete();

  @override
  Future<void> stop() async {
    stopCount += 1;
    await _stopGate?.future;
    _stopGate = null;
  }
}
