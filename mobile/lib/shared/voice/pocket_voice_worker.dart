import 'dart:async';
import 'dart:isolate';

import 'pocket_voice_ffi.dart';

sealed class PocketWorkerResponse {
  const PocketWorkerResponse();
}

class PocketWorkerReady extends PocketWorkerResponse {
  final int handle;

  const PocketWorkerReady(this.handle);
}

class PocketWorkerAudio extends PocketWorkerResponse {
  final int generation;
  final TransferableTypedData data;
  final int sampleRate;
  final Duration synthesisTime;
  final bool isLast;

  const PocketWorkerAudio({
    required this.generation,
    required this.data,
    required this.sampleRate,
    required this.synthesisTime,
    required this.isLast,
  });
}

class PocketWorkerDone extends PocketWorkerResponse {
  final int generation;

  const PocketWorkerDone(this.generation);
}

enum PocketWorkerFailureKind { load, synthesis, cancelled }

class PocketWorkerFailure extends PocketWorkerResponse {
  final int? generation;
  final PocketWorkerFailureKind kind;
  final String message;
  final List<String> remainingTextChunks;

  const PocketWorkerFailure(
    this.kind,
    this.message, {
    this.generation,
    this.remainingTextChunks = const [],
  });
}

class PocketWorkerStopped extends PocketWorkerResponse {
  const PocketWorkerStopped();
}

sealed class _PocketWorkerCommand {
  const _PocketWorkerCommand();
}

class _Synthesize extends _PocketWorkerCommand {
  final int generation;
  final String text;

  const _Synthesize(this.generation, this.text);
}

class _Dispose extends _PocketWorkerCommand {
  const _Dispose();
}

class PocketVoiceWorker {
  final StreamController<PocketWorkerResponse> _responses =
      StreamController.broadcast();
  Isolate? _isolate;
  SendPort? _commands;
  int? _handle;
  PocketVoiceFfi? _mainFfi;
  ReceivePort? _receive;
  Completer<void>? _activeSynthesis;
  int? _activeGeneration;

  Stream<PocketWorkerResponse> get responses => _responses.stream;
  bool get isReady => _commands != null;

  Future<void> start(String modelPath) async {
    if (_isolate != null) return;
    final receive = ReceivePort();
    _receive = receive;
    final messages = receive.asBroadcastStream();
    _isolate = await Isolate.spawn(_workerMain, (
      receive.sendPort,
      modelPath,
    ), debugName: 'buzz-pocket-voice');
    final first = await messages.first;
    if (first is! (SendPort, PocketWorkerResponse)) {
      throw StateError('Pocket worker sent an invalid startup response.');
    }
    _commands = first.$1;
    if (first.$2 is PocketWorkerFailure) {
      _isolate?.kill();
      _isolate = null;
      receive.close();
      _receive = null;
      _commands = null;
      throw StateError((first.$2 as PocketWorkerFailure).message);
    }
    final ready = first.$2 as PocketWorkerReady;
    _handle = ready.handle;
    _mainFfi = PocketVoiceFfi();
    messages.listen((message) {
      if (message is! PocketWorkerResponse) return;
      if (_finishesActiveSynthesis(message)) {
        _activeSynthesis?.complete();
        _activeSynthesis = null;
        _activeGeneration = null;
      }
      _responses.add(message);
    });
  }

  void synthesize(int generation, String text) {
    final commands = _commands;
    final handle = _handle;
    final ffi = _mainFfi;
    if (commands == null || handle == null || ffi == null) {
      throw StateError('Pocket worker is not ready.');
    }
    if (_activeSynthesis != null) {
      throw StateError('Pocket worker already has an active synthesis.');
    }
    // Clear cancellation before publishing the command. Any cancel that
    // arrives after this point belongs to this generation and must stay set.
    ffi.resetCancel(handle);
    _activeGeneration = generation;
    _activeSynthesis = Completer<void>();
    commands.send(_Synthesize(generation, text));
  }

  void cancel() {
    final handle = _handle;
    if (handle != null) _mainFfi?.cancel(handle);
  }

  Future<void> cancelAndWait() async {
    final active = _activeSynthesis;
    if (active == null) return;
    cancel();
    await active.future;
  }

  Future<void> dispose() async {
    if (_responses.isClosed) return;
    await cancelAndWait();
    final commands = _commands;
    _commands = null;
    _handle = null;
    _mainFfi = null;
    if (commands != null) {
      final stopped = _responses.stream.firstWhere(
        (response) => response is PocketWorkerStopped,
      );
      commands.send(const _Dispose());
      await stopped;
    }
    _isolate?.kill();
    _isolate = null;
    _receive?.close();
    _receive = null;
    await _responses.close();
  }

  bool _finishesActiveSynthesis(PocketWorkerResponse response) {
    final activeGeneration = _activeGeneration;
    if (activeGeneration == null) return false;
    return switch (response) {
      PocketWorkerAudio(:final generation, :final isLast) =>
        generation == activeGeneration && isLast,
      PocketWorkerDone(:final generation) => generation == activeGeneration,
      PocketWorkerFailure(:final generation) => generation == activeGeneration,
      _ => false,
    };
  }
}

void _workerMain((SendPort, String) startup) {
  final output = startup.$1;
  final commands = ReceivePort();
  final ffi = PocketVoiceFfi();
  late final int handle;
  try {
    handle = ffi.create(startup.$2);
  } catch (error) {
    output.send((
      commands.sendPort,
      PocketWorkerFailure(PocketWorkerFailureKind.load, error.toString()),
    ));
    commands.close();
    return;
  }
  output.send((commands.sendPort, PocketWorkerReady(handle)));
  commands.listen((command) {
    switch (command) {
      case _Synthesize():
        late final List<String> chunks;
        try {
          chunks = ffi.prepareChunks(handle, command.text);
        } catch (error) {
          output.send(
            PocketWorkerFailure(
              PocketWorkerFailureKind.synthesis,
              error.toString(),
              generation: command.generation,
              remainingTextChunks: [command.text],
            ),
          );
          return;
        }
        if (chunks.isEmpty) {
          output.send(PocketWorkerDone(command.generation));
          return;
        }
        for (var index = 0; index < chunks.length; index += 1) {
          try {
            final stopwatch = Stopwatch()..start();
            final pcm = ffi.synthesize(handle, chunks[index]);
            stopwatch.stop();
            output.send(
              PocketWorkerAudio(
                generation: command.generation,
                data: TransferableTypedData.fromList([pcm.bytes]),
                sampleRate: pcm.sampleRate,
                synthesisTime: stopwatch.elapsed,
                isLast: index == chunks.length - 1,
              ),
            );
          } catch (error) {
            output.send(
              PocketWorkerFailure(
                error.toString().contains('synthesis cancelled')
                    ? PocketWorkerFailureKind.cancelled
                    : PocketWorkerFailureKind.synthesis,
                error.toString(),
                generation: command.generation,
                remainingTextChunks:
                    error.toString().contains('synthesis cancelled')
                    ? const []
                    : chunks.sublist(index),
              ),
            );
            break;
          }
        }
      case _Dispose():
        ffi.destroy(handle);
        commands.close();
        output.send(const PocketWorkerStopped());
        Isolate.exit();
    }
  });
}
