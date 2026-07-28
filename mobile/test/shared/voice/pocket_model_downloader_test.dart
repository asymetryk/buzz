import 'dart:io';
import 'dart:async';

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

      final directory = await downloader.install(
        (downloaded, total, file) => progress.add((downloaded, total, file)),
      );

      expect(await downloader.verify(directory, hashContents: true), isTrue);
      expect(await File('${directory.path}/tiny.bin').readAsString(), 'hello');
      expect(progress.last, (5, 5, 'tiny.bin'));
      expect(excluded, [directory.path]);
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
    expect(
      await Directory(
        '${temporary.path}/buzz/models/pocket-tts',
      ).list().isEmpty,
      isTrue,
    );
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
    final backup = Directory('${parent.path}/.pocket-tts-v3.old-crash');
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
}

PocketModelDownloader _downloader(
  Directory support,
  PocketModelArtifact artifact, {
  required http.Client client,
  int capacity = 1024 * 1024 * 1024,
  void Function(String)? excludeFromBackup,
}) => PocketModelDownloader(
  clientFactory: () => client,
  applicationSupportDirectory: () async => support,
  availableCapacity: (_) async => capacity,
  excludeFromBackup: (path) async => excludeFromBackup?.call(path),
  artifacts: [artifact],
  installationId: 'test',
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
