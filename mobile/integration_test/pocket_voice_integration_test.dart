import 'dart:io';

import 'package:buzz/shared/voice/pocket_model_downloader.dart';
import 'package:buzz/shared/voice/pocket_voice_worker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Pocket worker synthesizes valid PCM and cancels promptly',
    (tester) async {
      const configuredModelPath = String.fromEnvironment(
        'BUZZ_POCKET_MODEL_DIR',
      );
      const downloadModel = bool.fromEnvironment('BUZZ_POCKET_DOWNLOAD');
      var modelPath = configuredModelPath;
      Duration? downloadTime;
      if (modelPath.isEmpty && downloadModel) {
        final clock = Stopwatch()..start();
        final downloader = PocketModelDownloader();
        final directory = await downloader.install((downloaded, total, file) {
          if (downloaded == total) {
            debugPrint('Pocket model download complete: $file ($total bytes)');
          }
        });
        clock.stop();
        downloadTime = clock.elapsed;
        modelPath = directory.path;
        expect(await downloader.verify(directory, hashContents: true), isTrue);
      }
      if (modelPath.isEmpty) {
        fail(
          'Pass --dart-define=BUZZ_POCKET_MODEL_DIR=<device path> or '
          '--dart-define=BUZZ_POCKET_DOWNLOAD=true.',
        );
      }

      final worker = PocketVoiceWorker();
      await worker.start(modelPath);
      addTearDown(worker.dispose);

      final firstClock = Stopwatch()..start();
      worker.synthesize(1, 'Pocket voice is running on this mobile device.');
      final first = await worker.responses
          .where((response) => response is PocketWorkerAudio)
          .cast<PocketWorkerAudio>()
          .first
          .timeout(const Duration(seconds: 30));
      firstClock.stop();
      final bytes = first.data.materialize().asUint8List();
      _expectValidPcm(bytes, first.sampleRate);
      final audioSeconds = bytes.length / 2 / first.sampleRate;
      final rtf =
          first.synthesisTime.inMicroseconds /
          Duration.microsecondsPerSecond /
          audioSeconds;

      final warmClock = Stopwatch()..start();
      worker.synthesize(2, 'The engine stays warm for the next response.');
      final warm = await worker.responses
          .where((response) => response is PocketWorkerAudio)
          .cast<PocketWorkerAudio>()
          .where((audio) => audio.generation == 2)
          .first
          .timeout(const Duration(seconds: 30));
      warmClock.stop();
      _expectValidPcm(warm.data.materialize().asUint8List(), warm.sampleRate);

      final cancelClock = Stopwatch()..start();
      worker.synthesize(
        3,
        List.filled(
          20,
          'This deliberately long sentence gives cancellation time to interrupt.',
        ).join(' '),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      worker.cancel();
      final cancelled = await worker.responses
          .where((response) => response is PocketWorkerFailure)
          .cast<PocketWorkerFailure>()
          .where((failure) => failure.generation == 3)
          .first
          .timeout(const Duration(seconds: 10));
      cancelClock.stop();
      expect(cancelled.message, contains('cancelled'));

      // Emitted in a stable shape so simulator/device runs are easy to compare.
      debugPrint(
        'BUZZ_POCKET_METRICS '
        'first_pcm_ms=${firstClock.elapsedMilliseconds} '
        'synthesis_ms=${first.synthesisTime.inMilliseconds} '
        'audio_s=${audioSeconds.toStringAsFixed(3)} '
        'rtf=${rtf.toStringAsFixed(3)} '
        'warm_pcm_ms=${warmClock.elapsedMilliseconds} '
        'cancel_ms=${cancelClock.elapsedMilliseconds} '
        'download_ms=${downloadTime?.inMilliseconds ?? 0} '
        'rss_bytes=${ProcessInfo.currentRss} '
        'peak_rss_bytes=${ProcessInfo.maxRss}',
      );
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}

void _expectValidPcm(Uint8List bytes, int sampleRate) {
  expect(sampleRate, 24000);
  expect(bytes.length, greaterThan(4800));
  expect(bytes.length % 2, 0);
  expect(bytes.any((byte) => byte != 0), isTrue);
}
