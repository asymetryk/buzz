import 'dart:async';
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

  test(
    'ignores a stale cancellation after steering starts new speech',
    () async {
      final worker = _FakeWorker();
      final output = _FakeAudioOutput();
      final container = _container(worker, output);
      addTearDown(container.dispose);
      final notifier = container.read(pocketVoiceProvider.notifier);

      await notifier.enable('conversation');
      notifier.speak('conversation', 'Before steering.');
      await notifier.interrupt();
      notifier.speak('conversation', 'After steering.');
      await _flush();
      expect(worker.syntheses, [
        (1, 'Before steering.'),
        (2, 'After steering.'),
      ]);

      worker.emitCancelled(1);
      worker.emitAudio(2, [1, 2], isLast: true);
      await _flush();

      expect(output.played.single.$3, 2);
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
  test('uses Android system speech when the Pocket model is absent', () async {
    final worker = _FakeWorker();
    final output = _FakeAudioOutput();
    final container = _container(worker, output, modelReady: false);
    addTearDown(container.dispose);
    final notifier = container.read(pocketVoiceProvider.notifier);

    await notifier.enable('conversation');
    notifier.speak('conversation', 'Fallback response.');
    await _flush();

    expect(worker.startCount, 0);
    expect(output.systemSpoken, [(('Fallback response.'), 1)]);
    final state = container.read(pocketVoiceProvider);
    expect(state.phase, PocketVoicePhase.synthesizing);
    expect(state.backend, PocketVoiceBackend.androidSystem);
    expect(state.fallbackReason, PocketVoiceFallbackReason.modelUnavailable);
    expect(state.error, isNull);
    output.started();
    await _flush();
    expect(
      container.read(pocketVoiceProvider).phase,
      PocketVoicePhase.speaking,
    );
  });

  test(
    'splits long Android system speech without changing its order',
    () async {
      final worker = _FakeWorker();
      final output = _FakeAudioOutput();
      final container = _container(worker, output, modelReady: false);
      addTearDown(container.dispose);
      final notifier = container.read(pocketVoiceProvider.notifier);
      final first = List.filled(450, 'first').join(' ');
      final second = List.filled(450, 'second').join(' ');

      await notifier.enable('conversation');
      notifier.speak('conversation', '$first $second');
      await _flush();

      expect(output.systemSpoken.single.$1.length, lessThanOrEqualTo(4000));
      output.complete();
      await _flush();
      expect(output.systemSpoken, hasLength(2));
      expect(output.systemSpoken.last.$1.length, lessThanOrEqualTo(4000));
      expect(
        output.systemSpoken.map((speech) => speech.$1).join(' '),
        '$first $second',
      );
    },
  );

  test('falls back without error chatter when Pocket loading fails', () async {
    final worker = _FakeWorker()..startError = StateError('load failed');
    final output = _FakeAudioOutput();
    final container = _container(worker, output);
    addTearDown(container.dispose);
    final notifier = container.read(pocketVoiceProvider.notifier);

    await notifier.enable('conversation');
    notifier.speak('conversation', 'Fallback response.');
    await _flush();

    expect(worker.disposeCount, 1);
    expect(output.systemSpoken.single.$1, 'Fallback response.');
    final state = container.read(pocketVoiceProvider);
    expect(state.backend, PocketVoiceBackend.androidSystem);
    expect(state.fallbackReason, PocketVoiceFallbackReason.pocketLoadFailed);
    expect(state.error, isNull);
  });

  test(
    'reports an error only when Pocket and system speech are unavailable',
    () async {
      final worker = _FakeWorker();
      final output = _FakeAudioOutput()..systemAvailable = false;
      final container = _container(worker, output, modelReady: false);
      addTearDown(container.dispose);
      final notifier = container.read(pocketVoiceProvider.notifier);

      await expectLater(
        notifier.enable('conversation'),
        throwsA(isA<StateError>()),
      );
      final state = container.read(pocketVoiceProvider);
      expect(state.enabled, isFalse);
      expect(state.phase, PocketVoicePhase.off);
      expect(state.conversationKey, isNull);
      expect(state.error, isNotNull);
    },
  );

  test(
    'hands unspoken Pocket chunks to system speech without repeating audio',
    () async {
      final worker = _FakeWorker();
      final output = _FakeAudioOutput();
      final container = _container(worker, output);
      addTearDown(container.dispose);
      final notifier = container.read(pocketVoiceProvider.notifier);

      await notifier.enable('conversation');
      notifier.speak('conversation', 'First complete response.');
      notifier.speak('conversation', 'Second response with two chunks.');
      notifier.speak('conversation', 'Third queued response.');

      worker.emitAudio(1, [1, 2], isLast: true);
      await _flush();
      output.complete();
      await _flush();
      expect(worker.syntheses.last, (2, 'Second response with two chunks.'));

      worker.emitAudio(2, [3, 4], isLast: false);
      worker.emitFailure(
        2,
        remainingTextChunks: const ['unspoken second chunk'],
      );
      await _flush();
      expect(output.systemSpoken, isEmpty);

      output.complete();
      await _flush();
      expect(output.systemSpoken.single.$1, 'unspoken second chunk');
      expect(
        output.systemSpoken.map((speech) => speech.$1),
        isNot(contains('Second response with two chunks.')),
      );

      output.complete();
      await _flush();
      expect(output.systemSpoken.last.$1, 'Third queued response.');
    },
  );

  test(
    'disable cancels system speech and ignores its late completion',
    () async {
      final worker = _FakeWorker();
      final output = _FakeAudioOutput();
      final container = _container(worker, output, modelReady: false);
      addTearDown(container.dispose);
      final notifier = container.read(pocketVoiceProvider.notifier);

      await notifier.enable('conversation');
      notifier.speak('conversation', 'System response.');
      await _flush();
      await notifier.disable();
      output.complete();
      await _flush();

      expect(container.read(pocketVoiceProvider).phase, PocketVoicePhase.off);
      expect(output.stopCount, greaterThan(0));
      expect(output.shutdownCount, 1);
    },
  );

  test(
    'audio focus loss interrupts system speech without replaying it',
    () async {
      final worker = _FakeWorker();
      final output = _FakeAudioOutput();
      final container = _container(worker, output, modelReady: false);
      addTearDown(container.dispose);
      final notifier = container.read(pocketVoiceProvider.notifier);

      await notifier.enable('conversation');
      notifier.speak('conversation', 'Interrupted system response.');
      await _flush();
      output.interrupt();
      await _flush();

      expect(output.systemSpoken, [(('Interrupted system response.'), 1)]);
      expect(
        container.read(pocketVoiceProvider).phase,
        PocketVoicePhase.listening,
      );
    },
  );

  test('recovers from system speech to Pocket at a safe boundary', () async {
    final worker = _FakeWorker();
    final output = _FakeAudioOutput();
    final container = _container(
      worker,
      output,
      modelFactory: _MutablePocketModelNotifier.new,
    );
    addTearDown(container.dispose);
    final notifier = container.read(pocketVoiceProvider.notifier);
    final model =
        container.read(pocketModelProvider.notifier)
            as _MutablePocketModelNotifier;

    await notifier.enable('conversation');
    notifier.speak('conversation', 'System response.');
    await _flush();
    model.makeReady();
    output.complete();
    await _flush();

    notifier.speak('conversation', 'Pocket response.');
    await _flush();
    expect(worker.startCount, 1);
    expect(worker.syntheses, [(2, 'Pocket response.')]);
    expect(
      container.read(pocketVoiceProvider).backend,
      PocketVoiceBackend.pocket,
    );
  });

  test(
    'steering during Pocket promotion preserves the replacement request',
    () async {
      final worker = _FakeWorker(startPaused: true);
      final output = _FakeAudioOutput();
      final container = _container(
        worker,
        output,
        modelFactory: _MutablePocketModelNotifier.new,
      );
      addTearDown(container.dispose);
      final notifier = container.read(pocketVoiceProvider.notifier);
      final model =
          container.read(pocketModelProvider.notifier)
              as _MutablePocketModelNotifier;

      await notifier.enable('conversation');
      model.makeReady();
      notifier.speak('conversation', 'Superseded.');
      await _flush();
      final interrupting = notifier.interrupt();
      notifier.speak('conversation', 'After steering.');
      worker.finishStart();
      await interrupting;
      await _flush();

      expect(worker.syntheses, [(1, 'After steering.')]);
    },
  );

  test('resource pressure parks Pocket until the next foreground', () async {
    final firstWorker = _FakeWorker();
    final recoveredWorker = _FakeWorker();
    var factoryCalls = 0;
    final output = _FakeAudioOutput();
    final container = ProviderContainer(
      overrides: [
        relayConfigProvider.overrideWith(_TestRelayConfigNotifier.new),
        pocketModelProvider.overrideWith(_ReadyPocketModelNotifier.new),
        pocketVoiceWorkerFactoryProvider.overrideWithValue(() {
          factoryCalls += 1;
          return factoryCalls == 1 ? firstWorker : recoveredWorker;
        }),
        voiceAudioOutputProvider.overrideWithValue(output),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(pocketVoiceProvider.notifier);

    await notifier.enable('conversation');
    output.resourcePressure();
    await _flush();
    notifier.speak('conversation', 'Under pressure.');
    await _flush();
    expect(output.systemSpoken.single.$1, 'Under pressure.');

    output.complete();
    output.foreground();
    await _flush();
    notifier.speak('conversation', 'Recovered.');
    await _flush();
    expect(recoveredWorker.syntheses.single.$2, 'Recovered.');
  });

  test(
    'resource pressure parks Pocket while final audio is draining',
    () async {
      final worker = _FakeWorker();
      final output = _FakeAudioOutput();
      final container = _container(worker, output);
      addTearDown(container.dispose);
      final notifier = container.read(pocketVoiceProvider.notifier);

      await notifier.enable('conversation');
      notifier.speak('conversation', 'Already synthesized.');
      await _flush();
      worker.emitAudio(1, [1, 2], isLast: true);
      await _flush();
      expect(worker.isSynthesizing, isFalse);

      output.resourcePressure();
      await _flush();

      expect(worker.disposeCount, 1);
      expect(
        container.read(pocketVoiceProvider).fallbackReason,
        PocketVoiceFallbackReason.resourcePressure,
      );
      output.complete();
      await _flush();
      notifier.speak('conversation', 'Now use system speech.');
      await _flush();
      expect(output.systemSpoken.single.$1, 'Now use system speech.');
    },
  );

  test(
    'resource pressure parks Pocket after active synthesis cancels',
    () async {
      final worker = _FakeWorker();
      final output = _FakeAudioOutput();
      final container = _container(worker, output);
      addTearDown(container.dispose);
      final notifier = container.read(pocketVoiceProvider.notifier);

      await notifier.enable('conversation');
      notifier.speak('conversation', 'Cancelled by pressure.');
      await _flush();
      worker.emitAudio(1, [1, 2], isLast: false);
      await _flush();
      expect(output.played.single.$1, [1, 2]);
      output.resourcePressure();
      await _flush();
      expect(worker.cancelCount, greaterThan(0));

      worker.emitCancelled(
        1,
        remainingTextChunks: const ['Unspoken remainder.'],
      );
      await _flush();

      expect(worker.disposeCount, 1);
      expect(output.systemSpoken, isEmpty);
      output.complete();
      await _flush();
      expect(output.systemSpoken.single.$1, 'Unspoken remainder.');
      expect(
        output.systemSpoken.map((speech) => speech.$1),
        isNot(contains('Cancelled by pressure.')),
      );
      expect(
        container.read(pocketVoiceProvider).fallbackReason,
        PocketVoiceFallbackReason.resourcePressure,
      );
    },
  );
}

ProviderContainer _container(
  _FakeWorker worker,
  _FakeAudioOutput output, {
  bool modelReady = true,
  PocketModelNotifier Function()? modelFactory,
}) => ProviderContainer(
  overrides: [
    relayConfigProvider.overrideWith(_TestRelayConfigNotifier.new),
    pocketModelProvider.overrideWith(
      modelFactory ??
          (modelReady
              ? _ReadyPocketModelNotifier.new
              : _AbsentPocketModelNotifier.new),
    ),
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

class _AbsentPocketModelNotifier extends PocketModelNotifier {
  @override
  PocketModelState build() =>
      const PocketModelState(phase: PocketModelPhase.absent);
}

class _MutablePocketModelNotifier extends PocketModelNotifier {
  @override
  PocketModelState build() =>
      const PocketModelState(phase: PocketModelPhase.absent);

  void makeReady() {
    state = const PocketModelState(
      phase: PocketModelPhase.ready,
      path: '/tmp/pocket-model',
    );
  }
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
  bool _synthesizing = false;
  int startCount = 0;
  int disposeCount = 0;
  int cancelCount = 0;
  Object? startError;

  _FakeWorker({bool startPaused = false})
    : _startGate = startPaused ? Completer<void>() : null;

  @override
  Stream<PocketWorkerResponse> get responses => _controller.stream;

  @override
  bool get isReady => _ready;

  @override
  bool get isSynthesizing => _synthesizing;

  @override
  Future<void> start(String modelPath) async {
    startCount += 1;
    await _startGate?.future;
    final error = startError;
    if (error != null) throw error;
    _ready = true;
  }

  void finishStart() => _startGate?.complete();

  @override
  void synthesize(int generation, String text) {
    _synthesizing = true;
    syntheses.add((generation, text));
  }

  void emitAudio(int generation, List<int> bytes, {required bool isLast}) {
    if (isLast) _synthesizing = false;
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
    List<String> remainingTextChunks = const [],
  }) {
    _synthesizing = false;
    _controller.add(
      PocketWorkerFailure(
        PocketWorkerFailureKind.synthesis,
        'Pocket synthesis failed.',
        generation: generation,
        remainingTextChunks: remainingTextChunks,
      ),
    );
  }

  void emitCancelled(
    int generation, {
    List<String> remainingTextChunks = const [],
  }) {
    _synthesizing = false;
    _controller.add(
      PocketWorkerFailure(
        PocketWorkerFailureKind.cancelled,
        'Pocket synthesis cancelled.',
        generation: generation,
        remainingTextChunks: remainingTextChunks,
      ),
    );
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
  final List<(List<int>, int, int)> played = [];
  final List<(String, int)> systemSpoken = [];
  bool systemAvailable = true;
  int stopCount = 0;
  int shutdownCount = 0;
  VoiceAudioBackend? _activeBackend;
  int? _activeGeneration;

  @override
  Stream<VoiceAudioEvent> get events => _controller.stream;

  @override
  Future<bool> systemTtsAvailable() async => systemAvailable;

  @override
  Future<void> play(Uint8List pcm, int sampleRate, int generation) async {
    played.add((pcm.toList(), sampleRate, generation));
    _activeBackend = VoiceAudioBackend.pocket;
    _activeGeneration = generation;
  }

  @override
  Future<void> speakSystem(String text, int generation) async {
    systemSpoken.add((text, generation));
    _activeBackend = VoiceAudioBackend.androidSystem;
    _activeGeneration = generation;
  }

  void complete() => _controller.add(
    VoiceAudioEvent(
      VoiceAudioEventType.completed,
      backend: _activeBackend,
      generation: _activeGeneration,
    ),
  );

  void started() => _controller.add(
    VoiceAudioEvent(
      VoiceAudioEventType.started,
      backend: _activeBackend,
      generation: _activeGeneration,
    ),
  );

  void fail() => _controller.add(
    VoiceAudioEvent(
      VoiceAudioEventType.error,
      backend: _activeBackend,
      generation: _activeGeneration,
    ),
  );

  void interrupt() => _controller.add(
    VoiceAudioEvent(
      VoiceAudioEventType.interrupted,
      backend: _activeBackend,
      generation: _activeGeneration,
    ),
  );

  void foreground() =>
      _controller.add(const VoiceAudioEvent(VoiceAudioEventType.foregrounded));

  void resourcePressure() => _controller.add(
    const VoiceAudioEvent(VoiceAudioEventType.resourcePressure),
  );

  @override
  Future<void> stop() async {
    stopCount += 1;
    _activeBackend = null;
    _activeGeneration = null;
  }

  @override
  Future<void> shutdownSystemTts() async {
    shutdownCount += 1;
  }
}
