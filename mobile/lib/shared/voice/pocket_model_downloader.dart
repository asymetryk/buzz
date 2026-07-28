import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:uuid/uuid.dart';

import 'pocket_model_manifest.dart';

const _manifestName = '.buzz-model-manifest';
const _legacyJanuaryModelVersion = '3';
const _storageChannel = MethodChannel('buzz/voice_audio');
const _minimumReserveBytes = 64 * 1024 * 1024;
const _defaultSendTimeout = Duration(seconds: 30);
const _defaultBodyIdleTimeout = Duration(seconds: 30);

class PocketDownloadCancelled implements Exception {
  const PocketDownloadCancelled();
}

class PocketInsufficientSpace implements Exception {
  final int required;
  final int available;

  const PocketInsufficientSpace(this.required, this.available);
}

class PocketModelDownloadException implements Exception {
  final String message;
  final bool retryable;

  const PocketModelDownloadException(this.message, {this.retryable = false});

  @override
  String toString() => message;
}

typedef PocketDownloadProgress =
    void Function(int downloaded, int total, String currentFile);

class PocketModelDownloader {
  final http.Client Function() clientFactory;
  final Future<Directory> Function() applicationSupportDirectory;
  final Future<int> Function(String path) availableCapacity;
  final Future<void> Function(String path) excludeFromBackup;
  final PocketModelVariant variant;
  final List<PocketModelArtifact> artifacts;
  final String installationId;
  final Duration sendTimeout;
  final Duration bodyIdleTimeout;

  http.Client? _client;
  bool _cancelled = false;

  PocketModelDownloader({
    http.Client Function()? clientFactory,
    Future<Directory> Function()? applicationSupportDirectory,
    Future<int> Function(String path)? availableCapacity,
    Future<void> Function(String path)? excludeFromBackup,
    this.variant = PocketModelVariant.higherQuality,
    this.artifacts = const [],
    String? installationId,
    this.sendTimeout = _defaultSendTimeout,
    this.bodyIdleTimeout = _defaultBodyIdleTimeout,
  }) : clientFactory = clientFactory ?? http.Client.new,
       applicationSupportDirectory =
           applicationSupportDirectory ?? getApplicationSupportDirectory,
       availableCapacity = availableCapacity ?? _platformAvailableCapacity,
       excludeFromBackup = excludeFromBackup ?? _platformExcludeFromBackup,
       installationId = installationId ?? const Uuid().v4();

  List<PocketModelArtifact> get _artifacts =>
      artifacts.isEmpty ? pocketModelArtifacts[variant]! : artifacts;

  int get _downloadBytes =>
      _artifacts.fold(0, (total, artifact) => total + artifact.size);

  Future<Directory> modelDirectory() async {
    final support = await applicationSupportDirectory();
    return Directory(
      '${support.path}/buzz/models/pocket-tts/'
      'v$pocketModelVersion/${variant.cacheKey}',
    );
  }

  Future<bool> isReady() async {
    final directory = await modelDirectory();
    if (await verify(directory, hashContents: false)) return true;
    if (variant == PocketModelVariant.higherQuality &&
        await _migrateLegacyFp32(directory)) {
      return true;
    }
    return false;
  }

  Future<bool> verify(Directory directory, {required bool hashContents}) async {
    final manifest = File('${directory.path}/$_manifestName');
    if (!await manifest.isFile()) return false;
    try {
      final decoded =
          jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
      if (decoded['version'] != pocketModelVersion ||
          decoded['revision'] != pocketModelRevision ||
          decoded['precision'] != variant.precision ||
          decoded['complete'] != true) {
        return false;
      }
      for (final artifact in _artifacts) {
        final file = File('${directory.path}/${artifact.name}');
        if (!await file.isFile() || await file.length() != artifact.size) {
          return false;
        }
        if (hashContents && await _sha256File(file) != artifact.sha256) {
          return false;
        }
      }
      return File('${directory.path}/MODEL_LICENSE.txt').isFile();
    } catch (_) {
      return false;
    }
  }

  Future<Directory> install(PocketDownloadProgress onProgress) async {
    _cancelled = false;
    final finalDirectory = await modelDirectory();
    final root = finalDirectory.parent.parent;
    await finalDirectory.parent.create(recursive: true);
    await _cleanupAbandoned(root, finalDirectory.path);

    final available = await availableCapacity(root.path);
    final reserve = max(_minimumReserveBytes, (_downloadBytes * 0.1).ceil());
    final required = _downloadBytes + reserve;
    if (available < required) {
      throw PocketInsufficientSpace(required, available);
    }

    final staging = Directory(
      '${root.path}/.pocket-tts-v$pocketModelVersion-'
      '${variant.cacheKey}.install-$installationId',
    );
    await staging.create(recursive: true);
    await excludeFromBackup(staging.path);
    var downloaded = 0;
    _client = clientFactory();
    try {
      for (final artifact in _artifacts) {
        _throwIfCancelled();
        await _ensureCapacity(root.path, artifact.size);
        await _downloadArtifact(
          artifact,
          staging,
          (fileBytes) =>
              onProgress(downloaded + fileBytes, _downloadBytes, artifact.name),
        );
        downloaded += artifact.size;
        onProgress(downloaded, _downloadBytes, artifact.name);
      }

      await File(
        '${staging.path}/MODEL_LICENSE.txt',
      ).writeAsString(pocketModelLicenseText, flush: true);
      await _writeManifest(staging);
      if (!await verify(staging, hashContents: true)) {
        throw const PocketModelDownloadException(
          'Pocket model verification failed after download.',
        );
      }

      final backup = Directory(
        '${root.path}/.pocket-tts-v$pocketModelVersion-'
        '${variant.cacheKey}.old-$installationId',
      );
      if (await finalDirectory.exists()) {
        await finalDirectory.rename(backup.path);
      }
      try {
        await staging.rename(finalDirectory.path);
      } catch (_) {
        if (await backup.exists() && !await finalDirectory.exists()) {
          await backup.rename(finalDirectory.path);
        }
        rethrow;
      }
      if (await backup.exists()) {
        await backup.delete(recursive: true);
      }
      await excludeFromBackup(finalDirectory.path);
      return finalDirectory;
    } on PocketDownloadCancelled {
      rethrow;
    } finally {
      _client?.close();
      _client = null;
      if (await staging.exists()) {
        await staging.delete(recursive: true);
      }
    }
  }

  void cancel() {
    _cancelled = true;
    _client?.close();
  }

  Future<void> _downloadArtifact(
    PocketModelArtifact artifact,
    Directory staging,
    void Function(int fileBytes) onProgress,
  ) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt += 1) {
      _throwIfCancelled();
      final part = File('${staging.path}/${artifact.name}.part');
      if (await part.exists()) await part.delete();
      try {
        final request = http.Request('GET', artifact.url);
        final response = await _client!.send(request).timeout(sendTimeout);
        if (response.statusCode != HttpStatus.ok) {
          final retryable =
              response.statusCode == 408 ||
              response.statusCode == 429 ||
              response.statusCode >= 500;
          throw PocketModelDownloadException(
            '${artifact.name} download returned HTTP '
            '${response.statusCode}.',
            retryable: retryable,
          );
        }
        if (response.contentLength case final length?
            when length != artifact.size) {
          throw PocketModelDownloadException(
            '${artifact.name} expected ${artifact.size} bytes, '
            'server reported $length.',
          );
        }

        final digest = SHA256Digest();
        final sink = part.openWrite();
        var bytes = 0;
        try {
          await for (final chunk in response.stream.timeout(bodyIdleTimeout)) {
            _throwIfCancelled();
            bytes += chunk.length;
            if (bytes > artifact.size) {
              throw PocketModelDownloadException(
                '${artifact.name} exceeded ${artifact.size} bytes.',
              );
            }
            final typed = Uint8List.fromList(chunk);
            digest.update(typed, 0, typed.length);
            sink.add(chunk);
            onProgress(bytes);
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        if (bytes != artifact.size) {
          throw PocketModelDownloadException(
            '${artifact.name} expected ${artifact.size} bytes, received $bytes.',
            retryable: true,
          );
        }
        final output = Uint8List(digest.digestSize);
        digest.doFinal(output, 0);
        final hash = output
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join();
        if (hash != artifact.sha256) {
          throw PocketModelDownloadException(
            '${artifact.name} checksum did not match.',
          );
        }
        await part.rename('${staging.path}/${artifact.name}');
        return;
      } on PocketDownloadCancelled {
        rethrow;
      } catch (error) {
        _throwIfCancelled();
        lastError = error;
        if (await part.exists()) await part.delete();
        final retryable =
            error is SocketException ||
            error is TimeoutException ||
            (error is PocketModelDownloadException && error.retryable);
        if (!retryable || attempt == 2) break;
        if (error is TimeoutException || error is SocketException) {
          _client?.close();
          _client = clientFactory();
        }
        await Future<void>.delayed(Duration(milliseconds: 250 << attempt));
      }
    }
    if (lastError is PocketModelDownloadException) throw lastError;
    throw PocketModelDownloadException(
      'Unable to download ${artifact.name}: $lastError',
      retryable: true,
    );
  }

  Future<void> _ensureCapacity(String path, int nextFileBytes) async {
    final available = await availableCapacity(path);
    final reserve = max(_minimumReserveBytes, (nextFileBytes * 0.1).ceil());
    if (available < nextFileBytes + reserve) {
      throw PocketInsufficientSpace(nextFileBytes + reserve, available);
    }
  }

  Future<void> _cleanupAbandoned(Directory root, String finalPath) async {
    if (!await root.exists()) return;
    final finalDirectory = Directory(finalPath);
    final backups = <Directory>[];
    await for (final entity in root.list()) {
      if (entity.path == finalPath) continue;
      final name = entity.uri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .last;
      if (entity is! Directory) continue;
      final prefix = '.pocket-tts-v$pocketModelVersion-${variant.cacheKey}.';
      if (name.startsWith('${prefix}old-')) {
        backups.add(entity);
      } else if (name.startsWith('${prefix}install-')) {
        await entity.delete(recursive: true);
      }
    }
    if (!await finalDirectory.exists() && backups.isNotEmpty) {
      backups.sort(
        (left, right) =>
            right.statSync().modified.compareTo(left.statSync().modified),
      );
      await backups.removeAt(0).rename(finalPath);
    }
    for (final backup in backups) {
      if (await backup.exists()) await backup.delete(recursive: true);
    }
  }

  Future<void> deleteCache() async {
    final directory = await modelDirectory();
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } on FileSystemException {
      // Cleanup is opportunistic. The selected verified cache remains usable.
    }
    if (variant == PocketModelVariant.higherQuality) {
      await deleteLegacyCaches();
    }
  }

  Future<void> deleteLegacyCaches() async {
    final directory = await modelDirectory();
    final root = directory.parent.parent;
    try {
      for (final version in [
        pocketLegacyFp32Version,
        _legacyJanuaryModelVersion,
      ]) {
        final legacy = Directory('${root.path}/v$version');
        if (await legacy.exists()) await legacy.delete(recursive: true);
      }
    } on FileSystemException {
      // A later readiness check retries cleanup.
    }
  }

  Future<bool> _migrateLegacyFp32(Directory finalDirectory) async {
    final root = finalDirectory.parent.parent;
    final legacy = Directory('${root.path}/v$pocketLegacyFp32Version');
    await _recoverLegacyFp32Backup(root, legacy);
    final staged = await _legacyMigrationStaging(root);
    if (!await finalDirectory.exists()) {
      for (final candidate in staged.toList()) {
        if (!await verify(candidate, hashContents: false)) continue;
        await finalDirectory.parent.create(recursive: true);
        await candidate.rename(finalDirectory.path);
        staged.remove(candidate);
        await excludeFromBackup(finalDirectory.path);
        await _deleteOpportunistically(
          Directory('${root.path}/v$_legacyJanuaryModelVersion'),
        );
        for (final extra in staged) {
          await _deleteOpportunistically(extra);
        }
        return true;
      }
    }
    if (!await legacy.exists()) {
      for (final candidate in staged.toList()) {
        if (!await _verifyLegacyFp32(candidate)) continue;
        await candidate.rename(legacy.path);
        staged.remove(candidate);
        break;
      }
    }
    for (final extra in staged) {
      await _deleteOpportunistically(extra);
    }

    final staging = Directory(
      '${root.path}/.pocket-tts-v$pocketModelVersion-fp32.'
      'migrate-$installationId',
    );
    if (!await _verifyLegacyFp32(legacy)) return false;

    await finalDirectory.parent.create(recursive: true);
    await legacy.rename(staging.path);
    try {
      await _writeManifest(staging);
      if (!await verify(staging, hashContents: false)) {
        throw const PocketModelDownloadException(
          'Migrated Pocket model verification failed.',
        );
      }
      await staging.rename(finalDirectory.path);
      await excludeFromBackup(finalDirectory.path);
      final january = Directory('${root.path}/v$_legacyJanuaryModelVersion');
      await _deleteOpportunistically(january);
      return true;
    } catch (_) {
      if (await staging.exists() && !await legacy.exists()) {
        await staging.rename(legacy.path);
      }
      rethrow;
    }
  }

  Future<List<Directory>> _legacyMigrationStaging(Directory root) async {
    if (!await root.exists()) return [];
    final candidates = <Directory>[];
    final prefix = '.pocket-tts-v$pocketModelVersion-fp32.migrate-';
    await for (final entity in root.list()) {
      if (entity is! Directory) continue;
      final name = entity.uri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .last;
      if (name.startsWith(prefix)) candidates.add(entity);
    }
    candidates.sort(
      (left, right) =>
          right.statSync().modified.compareTo(left.statSync().modified),
    );
    return candidates;
  }

  Future<void> _recoverLegacyFp32Backup(
    Directory root,
    Directory legacy,
  ) async {
    if (!await root.exists()) return;
    final backups = <Directory>[];
    await for (final entity in root.list()) {
      if (entity is! Directory) continue;
      final name = entity.uri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .last;
      if (name.startsWith('.pocket-tts-v$pocketLegacyFp32Version.old-')) {
        backups.add(entity);
      }
    }
    backups.sort(
      (left, right) =>
          right.statSync().modified.compareTo(left.statSync().modified),
    );
    if (!await legacy.exists()) {
      for (final backup in backups.toList()) {
        if (!await _verifyLegacyFp32(backup)) continue;
        await backup.rename(legacy.path);
        backups.remove(backup);
        break;
      }
    }
    for (final backup in backups) {
      await _deleteOpportunistically(backup);
    }
  }

  Future<void> _deleteOpportunistically(Directory directory) async {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } on FileSystemException {
      // A later readiness check retries stale-cache cleanup.
    }
  }

  Future<bool> _verifyLegacyFp32(Directory directory) async {
    final manifest = File('${directory.path}/$_manifestName');
    if (!await manifest.isFile()) return false;
    try {
      final decoded =
          jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
      if (decoded['version'] != pocketLegacyFp32Version ||
          decoded['revision'] != pocketModelRevision ||
          decoded['precision'] != PocketModelVariant.higherQuality.precision ||
          decoded['complete'] != true) {
        return false;
      }
      for (final artifact in _artifacts) {
        final file = File('${directory.path}/${artifact.name}');
        if (!await file.isFile() || await file.length() != artifact.size) {
          return false;
        }
      }
      return File('${directory.path}/MODEL_LICENSE.txt').isFile();
    } catch (_) {
      return false;
    }
  }

  Future<void> _writeManifest(Directory directory) =>
      File('${directory.path}/$_manifestName').writeAsString(
        jsonEncode({
          'version': pocketModelVersion,
          'revision': pocketModelRevision,
          'precision': variant.precision,
          'complete': true,
          'artifacts': [
            for (final artifact in _artifacts)
              {
                'name': artifact.name,
                'size': artifact.size,
                'sha256': artifact.sha256,
              },
          ],
        }),
        flush: true,
      );

  void _throwIfCancelled() {
    if (_cancelled) throw const PocketDownloadCancelled();
  }
}

Future<String> _sha256File(File file) async {
  final digest = SHA256Digest();
  await for (final chunk in file.openRead()) {
    final typed = Uint8List.fromList(chunk);
    digest.update(typed, 0, typed.length);
  }
  final output = Uint8List(digest.digestSize);
  digest.doFinal(output, 0);
  return output.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

Future<int> _platformAvailableCapacity(String path) async =>
    await _storageChannel.invokeMethod<int>('availableCapacity', path) ?? 0;

Future<void> _platformExcludeFromBackup(String path) =>
    _storageChannel.invokeMethod<void>('excludeFromBackup', path);

extension on File {
  Future<bool> isFile() async =>
      await exists() &&
      await stat().then((stat) => stat.type == FileSystemEntityType.file);
}
