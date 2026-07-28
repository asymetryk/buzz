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

  const PocketWorkerAudio({
    required this.generation,
    required this.data,
    required this.sampleRate,
    required this.synthesisTime,
  });
}

class PocketWorkerFailure extends PocketWorkerResponse {
  final int? generation;
  final String message;

  const PocketWorkerFailure(this.message, {this.generation});
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

  Stream<PocketWorkerResponse> get responses => _responses.stream;
  int? get handle => _handle;

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
      throw StateError((first.$2 as PocketWorkerFailure).message);
    }
    final ready = first.$2 as PocketWorkerReady;
    _handle = ready.handle;
    _mainFfi = PocketVoiceFfi();
    messages.listen((message) {
      if (message is PocketWorkerResponse) _responses.add(message);
    });
  }

  void synthesize(int generation, String text) {
    _commands?.send(_Synthesize(generation, text));
  }

  void cancel() {
    final handle = _handle;
    if (handle != null) _mainFfi?.cancel(handle);
  }

  Future<void> dispose() async {
    if (_responses.isClosed) return;
    cancel();
    final stopped = _responses.stream.firstWhere(
      (response) => response is PocketWorkerStopped,
    );
    final commands = _commands;
    _commands = null;
    _handle = null;
    _mainFfi = null;
    commands?.send(const _Dispose());
    if (commands != null) {
      try {
        await stopped.timeout(const Duration(seconds: 10));
      } on TimeoutException {
        _isolate?.kill();
      }
    }
    _isolate?.kill();
    _isolate = null;
    _receive?.close();
    _receive = null;
    await _responses.close();
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
    output.send((commands.sendPort, PocketWorkerFailure(error.toString())));
    commands.close();
    return;
  }
  output.send((commands.sendPort, PocketWorkerReady(handle)));
  commands.listen((command) {
    switch (command) {
      case _Synthesize():
        final stopwatch = Stopwatch()..start();
        try {
          final pcm = ffi.synthesize(handle, command.text);
          stopwatch.stop();
          output.send(
            PocketWorkerAudio(
              generation: command.generation,
              data: TransferableTypedData.fromList([pcm.bytes]),
              sampleRate: pcm.sampleRate,
              synthesisTime: stopwatch.elapsed,
            ),
          );
        } catch (error) {
          output.send(
            PocketWorkerFailure(
              error.toString(),
              generation: command.generation,
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
