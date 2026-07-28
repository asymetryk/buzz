import 'dart:io';

import 'package:buzz/shared/theme/theme.dart';
import 'package:buzz/shared/voice/pocket_model_downloader.dart';
import 'package:buzz/shared/voice/pocket_model_manifest.dart';
import 'package:buzz/shared/voice/pocket_model_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('buzz-pocket-selection-');
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test('persists Faster only after download and engine validation', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final fp32 = _FakeDownloader(
      variant: PocketModelVariant.higherQuality,
      directory: Directory('${temporary.path}/fp32'),
      ready: true,
    );
    final int8 = _FakeDownloader(
      variant: PocketModelVariant.faster,
      directory: Directory('${temporary.path}/int8'),
    );
    final validated = <PocketModelVariant>[];
    final container = ProviderContainer(
      overrides: [
        savedPrefsProvider.overrideWithValue(preferences),
        pocketModelDownloaderProvider.overrideWith(
          (_, variant) =>
              variant == PocketModelVariant.higherQuality ? fp32 : int8,
        ),
        pocketModelValidatorProvider.overrideWithValue((_, variant) async {
          validated.add(variant);
        }),
      ],
    );
    addTearDown(container.dispose);
    await _settle(container);
    fp32.deleteCount = 0;
    int8.deleteCount = 0;

    await container
        .read(pocketModelProvider.notifier)
        .select(PocketModelVariant.faster);

    final state = container.read(pocketModelProvider);
    expect(state.phase, PocketModelPhase.ready);
    expect(state.variant, PocketModelVariant.faster);
    expect(state.path, int8.directory.path);
    expect(int8.installCount, 1);
    expect(validated, [PocketModelVariant.faster]);
    expect(preferences.getString('pocket_model_precision'), 'int8');
    expect(fp32.deleteCount, 1);
  });

  test('keeps the active cache and preference when validation fails', () async {
    SharedPreferences.setMockInitialValues({'pocket_model_precision': 'fp32'});
    final preferences = await SharedPreferences.getInstance();
    final fp32 = _FakeDownloader(
      variant: PocketModelVariant.higherQuality,
      directory: Directory('${temporary.path}/fp32'),
      ready: true,
    );
    final int8 = _FakeDownloader(
      variant: PocketModelVariant.faster,
      directory: Directory('${temporary.path}/int8'),
    );
    final container = ProviderContainer(
      overrides: [
        savedPrefsProvider.overrideWithValue(preferences),
        pocketModelDownloaderProvider.overrideWith(
          (_, variant) =>
              variant == PocketModelVariant.higherQuality ? fp32 : int8,
        ),
        pocketModelValidatorProvider.overrideWithValue(
          (_, _) async => throw StateError('unsupported device'),
        ),
      ],
    );
    addTearDown(container.dispose);
    await _settle(container);
    fp32.deleteCount = 0;
    int8.deleteCount = 0;

    await container
        .read(pocketModelProvider.notifier)
        .select(PocketModelVariant.faster);

    final state = container.read(pocketModelProvider);
    expect(state.phase, PocketModelPhase.ready);
    expect(state.variant, PocketModelVariant.higherQuality);
    expect(state.path, fp32.directory.path);
    expect(state.message, contains('Higher quality was kept'));
    expect(preferences.getString('pocket_model_precision'), 'fp32');
    expect(fp32.deleteCount, 0);
    expect(int8.deleteCount, 1);
  });

  test(
    'falls back to an installed variant when the preference is unavailable',
    () async {
      SharedPreferences.setMockInitialValues({
        'pocket_model_precision': 'int8',
      });
      final preferences = await SharedPreferences.getInstance();
      final fp32 = _FakeDownloader(
        variant: PocketModelVariant.higherQuality,
        directory: Directory('${temporary.path}/fp32'),
        ready: true,
      );
      final int8 = _FakeDownloader(
        variant: PocketModelVariant.faster,
        directory: Directory('${temporary.path}/int8'),
      );
      final container = ProviderContainer(
        overrides: [
          savedPrefsProvider.overrideWithValue(preferences),
          pocketModelDownloaderProvider.overrideWith(
            (_, variant) =>
                variant == PocketModelVariant.higherQuality ? fp32 : int8,
          ),
        ],
      );
      addTearDown(container.dispose);

      await _settle(container);

      final state = container.read(pocketModelProvider);
      expect(state.variant, PocketModelVariant.higherQuality);
      expect(state.message, contains('Faster was unavailable'));
      expect(preferences.getString('pocket_model_precision'), 'fp32');
    },
  );

  test('readiness cleanup removes a stale inactive variant cache', () async {
    SharedPreferences.setMockInitialValues({'pocket_model_precision': 'fp32'});
    final preferences = await SharedPreferences.getInstance();
    final fp32 = _FakeDownloader(
      variant: PocketModelVariant.higherQuality,
      directory: Directory('${temporary.path}/fp32'),
      ready: true,
    );
    final int8 = _FakeDownloader(
      variant: PocketModelVariant.faster,
      directory: Directory('${temporary.path}/int8'),
      ready: true,
    );
    final container = ProviderContainer(
      overrides: [
        savedPrefsProvider.overrideWithValue(preferences),
        pocketModelDownloaderProvider.overrideWith(
          (_, variant) =>
              variant == PocketModelVariant.higherQuality ? fp32 : int8,
        ),
      ],
    );
    addTearDown(container.dispose);

    await _settle(container);

    expect(container.read(pocketModelProvider).variant, fp32.variant);
    expect(int8.deleteCount, 1);
  });
}

Future<void> _settle(ProviderContainer container) async {
  container.read(pocketModelProvider);
  for (var attempt = 0; attempt < 20; attempt += 1) {
    await Future<void>.delayed(Duration.zero);
    if (container.read(pocketModelProvider).phase !=
        PocketModelPhase.checking) {
      return;
    }
  }
  fail('Pocket model provider did not settle.');
}

class _FakeDownloader extends PocketModelDownloader {
  final Directory directory;
  bool ready;
  int installCount = 0;
  int deleteCount = 0;

  _FakeDownloader({
    required super.variant,
    required this.directory,
    this.ready = false,
  });

  @override
  Future<Directory> modelDirectory() async => directory;

  @override
  Future<bool> isReady() async => ready;

  @override
  Future<Directory> install(PocketDownloadProgress onProgress) async {
    installCount += 1;
    ready = true;
    onProgress(variant.runtimeBytes, variant.runtimeBytes, 'complete');
    return directory;
  }

  @override
  Future<void> deleteCache() async {
    deleteCount += 1;
    ready = false;
  }

  @override
  Future<void> deleteLegacyCaches() async {}
}
