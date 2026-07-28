import 'dart:io';

import 'package:buzz/shared/voice/pocket_model_downloader.dart';
import 'package:buzz/shared/voice/pocket_voice_worker.dart';
import 'package:buzz/shared/voice/voice_audio_output.dart';
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
      final firstPlaybackClock = Stopwatch()..start();
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
      final output = PlatformVoiceAudioOutput();
      final playbackStarted = output.events.firstWhere(
        (event) =>
            event.type == VoiceAudioEventType.started &&
            event.backend == VoiceAudioBackend.pocket &&
            event.generation == 1,
      );
      final playbackCompleted = output.events.firstWhere(
        (event) =>
            event.type == VoiceAudioEventType.completed &&
            event.backend == VoiceAudioBackend.pocket &&
            event.generation == 1,
      );
      final playbackClock = Stopwatch()..start();
      await output.play(bytes, first.sampleRate, 1);
      await playbackStarted.timeout(const Duration(seconds: 30));
      firstPlaybackClock.stop();
      await playbackCompleted.timeout(const Duration(seconds: 30));
      playbackClock.stop();
      expect(
        playbackClock.elapsedMilliseconds,
        greaterThanOrEqualTo((audioSeconds * 800).floor()),
      );

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

      final queuedCancelClock = Stopwatch()..start();
      worker.synthesize(
        3,
        List.filled(
          20,
          'This queued request must remain cancelled before synthesis begins.',
        ).join(' '),
      );
      worker.cancel();
      final queuedCancelled = await worker.responses
          .where((response) => response is PocketWorkerFailure)
          .cast<PocketWorkerFailure>()
          .where((failure) => failure.generation == 3)
          .first
          .timeout(const Duration(seconds: 10));
      queuedCancelClock.stop();
      expect(queuedCancelled.kind, PocketWorkerFailureKind.cancelled);

      final cancelClock = Stopwatch()..start();
      worker.synthesize(
        4,
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
          .where((failure) => failure.generation == 4)
          .first
          .timeout(const Duration(seconds: 10));
      cancelClock.stop();
      expect(cancelled.kind, PocketWorkerFailureKind.cancelled);

      // Emitted in a stable shape so simulator/device runs are easy to compare.
      debugPrint(
        'BUZZ_POCKET_METRICS '
        'first_pcm_ms=${firstClock.elapsedMilliseconds} '
        'ttfap_ms=${firstPlaybackClock.elapsedMilliseconds} '
        'synthesis_ms=${first.synthesisTime.inMilliseconds} '
        'audio_s=${audioSeconds.toStringAsFixed(3)} '
        'rtf=${rtf.toStringAsFixed(3)} '
        'playback_ms=${playbackClock.elapsedMilliseconds} '
        'warm_pcm_ms=${warmClock.elapsedMilliseconds} '
        'queued_cancel_ms=${queuedCancelClock.elapsedMilliseconds} '
        'cancel_ms=${cancelClock.elapsedMilliseconds} '
        'download_ms=${downloadTime?.inMilliseconds ?? 0} '
        'rss_bytes=${ProcessInfo.currentRss} '
        'peak_rss_bytes=${ProcessInfo.maxRss}',
      );
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );

  testWidgets(
    'Android installed default TTS speaks and cancels through the voice boundary',
    (tester) async {
      if (!Platform.isAndroid) return;
      final output = PlatformVoiceAudioOutput();
      expect(await output.systemTtsAvailable(), isTrue);

      final completed = output.events.firstWhere(
        (event) =>
            event.type == VoiceAudioEventType.completed &&
            event.backend == VoiceAudioBackend.androidSystem &&
            event.generation == 41,
      );
      await output.speakSystem(
        'Buzz Android system speech fallback is ready.',
        41,
      );
      await completed.timeout(const Duration(seconds: 30));

      var cancelledCompleted = false;
      final subscription = output.events.listen((event) {
        if (event.type == VoiceAudioEventType.completed &&
            event.backend == VoiceAudioBackend.androidSystem &&
            event.generation == 42) {
          cancelledCompleted = true;
        }
      });
      await output.speakSystem(
        List.filled(12, 'This sentence should be cancelled.').join(' '),
        42,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await output.stop();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await subscription.cancel();
      await output.shutdownSystemTts();

      expect(cancelledCompleted, isFalse);
      debugPrint(
        'BUZZ_ANDROID_SYSTEM_TTS default_engine=true '
        'completed_generation=41 cancelled_generation=42',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

void _expectValidPcm(Uint8List bytes, int sampleRate) {
  expect(sampleRate, 24000);
  expect(bytes.length, greaterThan(4800));
  expect(bytes.length % 2, 0);
  expect(bytes.any((byte) => byte != 0), isTrue);
}
