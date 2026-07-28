import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final class _EngineResult extends ffi.Struct {
  external ffi.Pointer<ffi.Void> engine;
  external ffi.Pointer<ffi.Char> error;
}

final class _PcmResult extends ffi.Struct {
  external ffi.Pointer<ffi.Int16> samples;

  @ffi.IntPtr()
  external int len;

  @ffi.Uint32()
  external int sampleRate;

  external ffi.Pointer<ffi.Char> error;
}

typedef _CreateNative = _EngineResult Function(ffi.Pointer<Utf8>);
typedef _CreateDart = _EngineResult Function(ffi.Pointer<Utf8>);
typedef _SynthNative =
    _PcmResult Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>);
typedef _SynthDart =
    _PcmResult Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>);
typedef _CancelNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _CancelDart = void Function(ffi.Pointer<ffi.Void>);
typedef _ResetCancelNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _ResetCancelDart = void Function(ffi.Pointer<ffi.Void>);
typedef _PrepareNative = ffi.Pointer<ffi.Char> Function(ffi.Pointer<Utf8>);
typedef _PrepareDart = ffi.Pointer<ffi.Char> Function(ffi.Pointer<Utf8>);
typedef _DestroyNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _DestroyDart = void Function(ffi.Pointer<ffi.Void>);
typedef _FreePcmNative = ffi.Void Function(_PcmResult);
typedef _FreePcmDart = void Function(_PcmResult);
typedef _FreeStringNative = ffi.Void Function(ffi.Pointer<ffi.Char>);
typedef _FreeStringDart = void Function(ffi.Pointer<ffi.Char>);

class PocketVoicePcm {
  final Uint8List bytes;
  final int sampleRate;

  const PocketVoicePcm(this.bytes, this.sampleRate);
}

class PocketVoiceFfi {
  final ffi.DynamicLibrary _library;
  late final _CreateDart _create;
  late final _SynthDart _synthesize;
  late final _CancelDart _cancel;
  late final _ResetCancelDart _resetCancel;
  late final _PrepareDart _prepare;
  late final _DestroyDart _destroy;
  late final _FreePcmDart _freePcm;
  late final _FreeStringDart _freeString;

  PocketVoiceFfi() : _library = _openLibrary() {
    _create = _library.lookupFunction<_CreateNative, _CreateDart>(
      'buzz_voice_engine_create',
    );
    _synthesize = _library.lookupFunction<_SynthNative, _SynthDart>(
      'buzz_voice_engine_synthesize',
    );
    _cancel = _library.lookupFunction<_CancelNative, _CancelDart>(
      'buzz_voice_engine_cancel',
    );
    _resetCancel = _library
        .lookupFunction<_ResetCancelNative, _ResetCancelDart>(
          'buzz_voice_engine_reset_cancel',
        );
    _prepare = _library.lookupFunction<_PrepareNative, _PrepareDart>(
      'buzz_voice_prepare_chunks_json',
    );
    _destroy = _library.lookupFunction<_DestroyNative, _DestroyDart>(
      'buzz_voice_engine_destroy',
    );
    _freePcm = _library.lookupFunction<_FreePcmNative, _FreePcmDart>(
      'buzz_voice_pcm_free',
    );
    _freeString = _library.lookupFunction<_FreeStringNative, _FreeStringDart>(
      'buzz_voice_string_free',
    );
  }

  int create(String modelPath) {
    final path = modelPath.toNativeUtf8();
    final result = _create(path);
    calloc.free(path);
    if (result.error != ffi.nullptr) {
      throw StateError(_takeError(result.error));
    }
    if (result.engine == ffi.nullptr) {
      throw StateError('Pocket engine creation returned a null handle.');
    }
    return result.engine.address;
  }

  PocketVoicePcm synthesize(int handle, String text) {
    final input = text.toNativeUtf8();
    final result = _synthesize(
      ffi.Pointer<ffi.Void>.fromAddress(handle),
      input,
    );
    calloc.free(input);
    try {
      if (result.error != ffi.nullptr) {
        throw StateError(result.error.cast<Utf8>().toDartString());
      }
      if (result.samples == ffi.nullptr) {
        throw StateError('Pocket synthesis returned a null sample buffer.');
      }
      final sampleBytes = result.samples.cast<ffi.Uint8>().asTypedList(
        result.len * 2,
      );
      return PocketVoicePcm(Uint8List.fromList(sampleBytes), result.sampleRate);
    } finally {
      _freePcm(result);
    }
  }

  void cancel(int handle) => _cancel(ffi.Pointer<ffi.Void>.fromAddress(handle));

  void resetCancel(int handle) =>
      _resetCancel(ffi.Pointer<ffi.Void>.fromAddress(handle));

  List<String> prepareChunks(String text) {
    final input = text.toNativeUtf8();
    final result = _prepare(input);
    calloc.free(input);
    if (result == ffi.nullptr) {
      throw StateError('Pocket text preparation returned no result.');
    }
    final encoded = _takeError(result);
    final decoded = jsonDecode(encoded);
    if (decoded is! List) {
      throw StateError('Pocket text preparation returned invalid JSON.');
    }
    return decoded.cast<String>();
  }

  void destroy(int handle) =>
      _destroy(ffi.Pointer<ffi.Void>.fromAddress(handle));

  String _takeError(ffi.Pointer<ffi.Char> error) {
    final message = error.cast<Utf8>().toDartString();
    _freeString(error);
    return message;
  }
}

ffi.DynamicLibrary _openLibrary() {
  if (Platform.isIOS) return ffi.DynamicLibrary.process();
  if (Platform.isAndroid) {
    return ffi.DynamicLibrary.open('libbuzz_voice_mobile.so');
  }
  throw UnsupportedError('Pocket voice is supported only on iOS and Android.');
}
