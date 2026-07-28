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
  final String? remainingText;

  const PocketWorkerFailure(
    this.kind,
    this.message, {
    this.generation,
    this.remainingText,
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
      StreamController.broadcast(sync: true);
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
        final active = _activeSynthesis;
        _activeSynthesis = null;
        _activeGeneration = null;
        _responses.add(message);
        active?.complete();
        return;
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
        var chunks = <String>[];
        var index = 0;
        try {
          chunks = ffi.prepareChunks(handle, command.text);
          if (chunks.isEmpty) {
            output.send(PocketWorkerDone(command.generation));
            return;
          }
          for (; index < chunks.length; index += 1) {
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
          }
        } catch (error) {
          final message = error.toString();
          output.send(
            PocketWorkerFailure(
              message.contains('synthesis cancelled')
                  ? PocketWorkerFailureKind.cancelled
                  : PocketWorkerFailureKind.synthesis,
              message,
              generation: command.generation,
              remainingText: chunks.isEmpty
                  ? command.text
                  : chunks.sublist(index).join(' '),
            ),
          );
        }
      case _Dispose():
        ffi.destroy(handle);
        commands.close();
        output.send(const PocketWorkerStopped());
        Isolate.exit();
    }
  });
}
