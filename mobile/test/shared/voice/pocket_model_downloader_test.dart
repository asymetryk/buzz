import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:buzz/shared/voice/pocket_model_downloader.dart';
import 'package:buzz/shared/voice/pocket_model_manifest.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory temporary;
  late PocketModelArtifact artifact;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('buzz-pocket-model-');
    artifact = PocketModelArtifact(
      name: 'tiny.bin',
      url: Uri.parse('https://example.test/tiny.bin'),
      size: 5,
      sha256:
          '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e730'
          '43362938b9824',
    );
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test(
    'installs verified files atomically and reports exact progress',
    () async {
      final excluded = <String>[];
      final progress = <(int, int, String)>[];
      final downloader = _downloader(
        temporary,
        artifact,
        client: MockClient((_) async => http.Response('hello', 200)),
        excludeFromBackup: excluded.add,
      );
      final legacy = Directory('${temporary.path}/buzz/models/pocket-tts/v3');
      await legacy.create(recursive: true);
      await File('${legacy.path}/sentinel').writeAsString('January');

      final directory = await downloader.install(
        (downloaded, total, file) => progress.add((downloaded, total, file)),
      );

      expect(await downloader.verify(directory, hashContents: true), isTrue);
      expect(await File('${directory.path}/tiny.bin').readAsString(), 'hello');
      final manifest =
          jsonDecode(
                await File(
                  '${directory.path}/.buzz-model-manifest',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      expect(manifest['version'], pocketModelVersion);
      expect(manifest['revision'], pocketModelRevision);
      expect(manifest['precision'], pocketModelPrecision);
      expect(progress.last, (5, 5, 'tiny.bin'));
      expect(await legacy.exists(), isFalse);
      expect(excluded, hasLength(2));
      expect(
        excluded.first,
        contains('.pocket-tts-v$pocketModelVersion.install-'),
      );
      expect(excluded.last, directory.path);
      expect(
        await directory.parent
            .list()
            .where((entry) => entry.path.contains('.install-'))
            .isEmpty,
        isTrue,
      );
    },
  );

  test('rejects a checksum mismatch without replacing an install', () async {
    final legacy = Directory('${temporary.path}/buzz/models/pocket-tts/v3');
    await legacy.create(recursive: true);
    await File('${legacy.path}/sentinel').writeAsString('January');
    final downloader = _downloader(
      temporary,
      artifact,
      client: MockClient((_) async => http.Response('wrong', 200)),
    );

    await expectLater(
      downloader.install((_, _, _) {}),
      throwsA(isA<PocketModelDownloadException>()),
    );

    expect(
      await downloader.modelDirectory().then((dir) => dir.exists()),
      isFalse,
    );
    expect(await File('${legacy.path}/sentinel').readAsString(), 'January');
  });

  test('fails before download when the model and reserve do not fit', () async {
    final downloader = _downloader(
      temporary,
      artifact,
      client: MockClient((_) async => http.Response('hello', 200)),
      capacity: 4,
    );

    await expectLater(
      downloader.install((_, _, _) {}),
      throwsA(
        isA<PocketInsufficientSpace>()
            .having((error) => error.available, 'available', 4)
            .having((error) => error.required, 'required', greaterThan(5)),
      ),
    );
  });

  test('cancellation closes the transfer and removes staging files', () async {
    final client = _PendingClient();
    final downloader = _downloader(temporary, artifact, client: client);

    final install = downloader.install((_, _, _) {});
    await client.started.future;
    downloader.cancel();

    await expectLater(install, throwsA(isA<PocketDownloadCancelled>()));
    expect(client.closed, isTrue);
    expect(
      await downloader.modelDirectory().then((directory) => directory.exists()),
      isFalse,
    );
  });

  test('recovers an old install left by an interrupted atomic swap', () async {
    final parent = Directory('${temporary.path}/buzz/models/pocket-tts');
    final backup = Directory(
      '${parent.path}/.pocket-tts-v$pocketModelVersion.old-crash',
    );
    await backup.create(recursive: true);
    await File('${backup.path}/sentinel').writeAsString('previous install');
    final client = _PendingClient();
    final downloader = _downloader(temporary, artifact, client: client);

    final install = downloader.install((_, _, _) {});
    await client.started.future;
    final finalDirectory = await downloader.modelDirectory();
    expect(
      await File('${finalDirectory.path}/sentinel').readAsString(),
      'previous install',
    );
    downloader.cancel();
    await expectLater(install, throwsA(isA<PocketDownloadCancelled>()));
  });

  test('replaces clients and retries when sending never completes', () async {
    final clients = <_NeverSendingClient>[];
    final downloader = _downloader(
      temporary,
      artifact,
      clientFactory: () {
        final client = _NeverSendingClient();
        clients.add(client);
        return client;
      },
      sendTimeout: const Duration(milliseconds: 5),
    );

    await expectLater(
      downloader.install((_, _, _) {}),
      throwsA(isA<PocketModelDownloadException>()),
    );

    expect(clients, hasLength(3));
    expect(clients.every((client) => client.closed), isTrue);
  });

  test('replaces the client and retries after a body idle timeout', () async {
    final stalled = _StallingBodyClient();
    final succeeding = MockClient((_) async => http.Response('hello', 200));
    final clients = <http.Client>[stalled, succeeding];
    var nextClient = 0;
    final downloader = _downloader(
      temporary,
      artifact,
      clientFactory: () => clients[nextClient++],
      bodyIdleTimeout: const Duration(milliseconds: 5),
    );

    final directory = await downloader.install((_, _, _) {});

    expect(await File('${directory.path}/tiny.bin').readAsString(), 'hello');
    expect(stalled.closed, isTrue);
    expect(nextClient, 2);
  });

  test('April FP32 manifest matches the frozen shared runtime metadata', () {
    expect(pocketModelVersion, '4');
    expect(pocketModelRevision, '58a6d00cf13d239b6748cb0769f35c580a8f606c');
    expect(pocketModelPrecision, 'fp32');
    expect(
      pocketModelArtifacts
          .where((artifact) => artifact.name != 'reference_sample.wav')
          .where((artifact) => artifact.name != 'LICENSE')
          .fold(0, (total, artifact) => total + artifact.size),
      pocketModelCoreBytes,
    );
    expect(
      pocketModelArtifacts.fold(0, (total, artifact) => total + artifact.size),
      pocketModelRuntimeBytes,
    );
    expect(
      pocketModelArtifacts.map((artifact) => artifact.name),
      containsAll([
        'bundle.json',
        'bos_before_voice.npy',
        'tokenizer.model',
        'flow_lm_main.onnx',
        'flow_lm_flow.onnx',
        'mimi_decoder.onnx',
        'mimi_encoder.onnx',
        'text_conditioner.onnx',
      ]),
    );
    expect(pocketModelLicenseText, contains('April 2026 ONNX export'));
    expect(pocketModelLicenseText, contains(pocketModelRevision));
  });
}

PocketModelDownloader _downloader(
  Directory support,
  PocketModelArtifact artifact, {
  http.Client? client,
  http.Client Function()? clientFactory,
  int capacity = 1024 * 1024 * 1024,
  void Function(String)? excludeFromBackup,
  Duration sendTimeout = const Duration(seconds: 30),
  Duration bodyIdleTimeout = const Duration(seconds: 30),
}) => PocketModelDownloader(
  clientFactory: clientFactory ?? () => client!,
  applicationSupportDirectory: () async => support,
  availableCapacity: (_) async => capacity,
  excludeFromBackup: (path) async => excludeFromBackup?.call(path),
  artifacts: [artifact],
  installationId: 'test',
  sendTimeout: sendTimeout,
  bodyIdleTimeout: bodyIdleTimeout,
);

class _PendingClient extends http.BaseClient {
  final started = Completer<void>();
  final _response = StreamController<List<int>>();
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    started.complete();
    return http.StreamedResponse(_response.stream, 200, contentLength: 5);
  }

  @override
  void close() {
    closed = true;
    unawaited(_response.close());
  }
}

class _NeverSendingClient extends http.BaseClient {
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future;

  @override
  void close() {
    closed = true;
  }
}

class _StallingBodyClient extends http.BaseClient {
  final _response = StreamController<List<int>>();
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    scheduleMicrotask(() => _response.add('he'.codeUnits));
    return http.StreamedResponse(_response.stream, 200, contentLength: 5);
  }

  @override
  void close() {
    closed = true;
    unawaited(_response.close());
  }
}
