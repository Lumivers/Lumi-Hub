import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ResourcePackageSnapshot {
  const ResourcePackageSnapshot({
    required this.bundleUrl,
    required this.bucketEndpoint,
    required this.bucketPrefix,
    required this.activeVersion,
    required this.rootPath,
    required this.installedCount,
    this.updatedAt,
  });

  final String bundleUrl;
  final String bucketEndpoint;
  final String bucketPrefix;
  final String activeVersion;
  final String rootPath;
  final int installedCount;
  final DateTime? updatedAt;
}

class ResourceBucketObject {
  const ResourceBucketObject({
    required this.key,
    required this.url,
    this.sizeBytes,
    this.lastModified,
  });

  final String key;
  final String url;
  final int? sizeBytes;
  final DateTime? lastModified;
}

class ResourcePackageInstallResult {
  const ResourcePackageInstallResult({
    required this.version,
    required this.fileCount,
    required this.outputPath,
  });

  final String version;
  final int fileCount;
  final String outputPath;
}

class ResourcePackageService {
  static const String _bundleUrlKey = 'resource.bundle_url';
  static const String _bucketEndpointKey = 'resource.bucket_endpoint';
  static const String _bucketPrefixKey = 'resource.bucket_prefix';
  static const String _activeVersionKey = 'resource.active_version';
  static const String _updatedAtMsKey = 'resource.updated_at_ms';

  Future<ResourcePackageSnapshot> loadSnapshot() async {
    final prefs = await SharedPreferences.getInstance();
    final root = await _resolveRootDir();
    final versionsDir = Directory(
      '${root.path}${Platform.pathSeparator}versions',
    );

    var installedCount = 0;
    if (await versionsDir.exists()) {
      final entries = await versionsDir.list().toList();
      installedCount = entries.whereType<Directory>().length;
    }

    final updatedMs = prefs.getInt(_updatedAtMsKey);
    return ResourcePackageSnapshot(
      bundleUrl: prefs.getString(_bundleUrlKey) ?? '',
      bucketEndpoint: prefs.getString(_bucketEndpointKey) ?? '',
      bucketPrefix: prefs.getString(_bucketPrefixKey) ?? '',
      activeVersion: prefs.getString(_activeVersionKey) ?? '',
      rootPath: root.path,
      installedCount: installedCount,
      updatedAt: updatedMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(updatedMs),
    );
  }

  Future<ResourcePackageInstallResult> downloadAndInstall({
    required String bundleUrl,
    String? versionHint,
    String? expectedSha256,
  }) async {
    final normalizedUrl = bundleUrl.trim();
    final uri = Uri.tryParse(normalizedUrl);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      throw Exception('资源包地址必须是 http/https URL');
    }

    final root = await _resolveRootDir();
    await root.create(recursive: true);

    final bytes = await _downloadBytes(uri);
    if (bytes.isEmpty) {
      throw Exception('下载结果为空');
    }

    if (expectedSha256 != null && expectedSha256.trim().isNotEmpty) {
      final actual = sha256.convert(bytes).toString().toLowerCase();
      final expected = expectedSha256.trim().toLowerCase();
      if (actual != expected) {
        throw Exception('资源包 SHA256 校验失败');
      }
    }

    final version = _resolveVersion(versionHint);
    final versionsDir = Directory(
      '${root.path}${Platform.pathSeparator}versions',
    );
    await versionsDir.create(recursive: true);

    final targetDir = Directory(
      '${versionsDir.path}${Platform.pathSeparator}$version',
    );
    final installingDir = Directory(
      '${versionsDir.path}${Platform.pathSeparator}._installing_$version',
    );

    if (await installingDir.exists()) {
      await installingDir.delete(recursive: true);
    }
    await installingDir.create(recursive: true);

    if (await targetDir.exists()) {
      await targetDir.delete(recursive: true);
    }

    final zipPath =
        '${installingDir.path}${Platform.pathSeparator}package.zip';
    await File(zipPath).writeAsBytes(bytes, flush: true);

    final unpackedDir = Directory(
      '${installingDir.path}${Platform.pathSeparator}unpacked',
    );
    await unpackedDir.create(recursive: true);

    final fileCount = await _extractZipSafely(bytes, unpackedDir);
    await installingDir.rename(targetDir.path);

    await File(
      '${root.path}${Platform.pathSeparator}current_version.txt',
    ).writeAsString(version, flush: true);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_bundleUrlKey, normalizedUrl);
    await prefs.setString(_activeVersionKey, version);
    await prefs.setInt(_updatedAtMsKey, DateTime.now().millisecondsSinceEpoch);

    await _cleanupOldVersions(versionsDir, keep: 2);

    return ResourcePackageInstallResult(
      version: version,
      fileCount: fileCount,
      outputPath: targetDir.path,
    );
  }

  Future<void> saveBucketSearchConfig({
    required String bucketEndpoint,
    required String bucketPrefix,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_bucketEndpointKey, bucketEndpoint.trim());
    await prefs.setString(_bucketPrefixKey, bucketPrefix.trim());
  }

  Future<List<ResourceBucketObject>> searchBucketZipPackages({
    required String bucketEndpoint,
    String bucketPrefix = '',
    String keyword = '',
    int maxKeys = 1000,
  }) async {
    final endpoint = bucketEndpoint.trim();
    final prefix = bucketPrefix.trim();
    final keyFilter = keyword.trim().toLowerCase();

    final baseUri = Uri.tryParse(endpoint);
    if (baseUri == null || !(baseUri.isScheme('http') || baseUri.isScheme('https'))) {
      throw Exception('Bucket 地址必须是 http/https URL');
    }

    await saveBucketSearchConfig(bucketEndpoint: endpoint, bucketPrefix: prefix);

    final query = <String, String>{
      'list-type': '2',
      'max-keys': maxKeys.toString(),
    };
    if (prefix.isNotEmpty) {
      query['prefix'] = prefix;
    }

    final listUri = baseUri.replace(queryParameters: query, fragment: '');
    final xmlBytes = await _downloadBytes(listUri);
    final xml = String.fromCharCodes(xmlBytes);
    final contents = _parseBucketContents(xml);

    final results = <ResourceBucketObject>[];
    for (final item in contents) {
      final lowerKey = item.key.toLowerCase();
      if (!lowerKey.endsWith('.zip')) {
        continue;
      }
      if (keyFilter.isNotEmpty && !lowerKey.contains(keyFilter)) {
        continue;
      }

      results.add(
        ResourceBucketObject(
          key: item.key,
          url: _buildObjectUrl(baseUri, item.key),
          sizeBytes: item.sizeBytes,
          lastModified: item.lastModified,
        ),
      );
    }

    results.sort((a, b) {
      final aTime = a.lastModified;
      final bTime = b.lastModified;
      if (aTime != null && bTime != null) {
        return bTime.compareTo(aTime);
      }
      if (aTime != null) return -1;
      if (bTime != null) return 1;
      return a.key.compareTo(b.key);
    });

    return results;
  }

  Future<Directory> _resolveRootDir() async {
    String? baseDir;
    if (Platform.isWindows) {
      baseDir = Platform.environment['LOCALAPPDATA'];
    }
    baseDir ??= Directory.systemTemp.path;

    return Directory(
      '$baseDir${Platform.pathSeparator}Lumi-Hub${Platform.pathSeparator}resource_packages',
    );
  }

  String _resolveVersion(String? versionHint) {
    final hint = (versionHint ?? '').trim();
    if (hint.isNotEmpty) {
      final sanitized = hint.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      if (sanitized.isNotEmpty) {
        return sanitized;
      }
    }
    return 'v${DateTime.now().millisecondsSinceEpoch}';
  }

  Future<List<int>> _downloadBytes(Uri uri) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 20);

    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw Exception('下载失败，HTTP ${response.statusCode}');
      }

      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  List<_BucketContentItem> _parseBucketContents(String xml) {
    final blockRegex = RegExp(r'<Contents>([\s\S]*?)</Contents>');
    final keyRegex = RegExp(r'<Key>([\s\S]*?)</Key>');
    final sizeRegex = RegExp(r'<Size>(\d+)</Size>');
    final timeRegex = RegExp(r'<LastModified>([\s\S]*?)</LastModified>');

    final result = <_BucketContentItem>[];

    for (final match in blockRegex.allMatches(xml)) {
      final block = match.group(1) ?? '';
      final keyRaw = keyRegex.firstMatch(block)?.group(1) ?? '';
      final key = _xmlUnescape(keyRaw).trim();
      if (key.isEmpty) continue;

      final sizeRaw = sizeRegex.firstMatch(block)?.group(1);
      final size = sizeRaw == null ? null : int.tryParse(sizeRaw);

      final timeRaw = timeRegex.firstMatch(block)?.group(1)?.trim() ?? '';
      final time = timeRaw.isEmpty ? null : DateTime.tryParse(timeRaw);

      result.add(
        _BucketContentItem(
          key: key,
          sizeBytes: size,
          lastModified: time,
        ),
      );
    }

    return result;
  }

  String _xmlUnescape(String input) {
    return input
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'");
  }

  String _buildObjectUrl(Uri bucketUri, String key) {
    final normalizedKey = key.replaceAll('\\', '/');
    final encodedKey = normalizedKey
        .split('/')
        .where((s) => s.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');

    final basePath = bucketUri.path.endsWith('/')
        ? bucketUri.path
        : '${bucketUri.path}/';

    return bucketUri
        .replace(
          path: '$basePath$encodedKey',
          query: null,
          fragment: null,
        )
        .toString();
  }

  Future<int> _extractZipSafely(List<int> bytes, Directory outputDir) async {
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    final rootPath = _normalizePath(outputDir.absolute.path);
    var fileCount = 0;

    for (final entry in archive) {
      final normalizedName = entry.name.replaceAll('\\', '/');
      if (normalizedName.isEmpty ||
          normalizedName.startsWith('/') ||
          normalizedName.contains('../')) {
        continue;
      }

      final outPath = _normalizePath(
        '${outputDir.path}${Platform.pathSeparator}$normalizedName',
      );
      if (!outPath.startsWith(rootPath)) {
        continue;
      }

      if (entry.isFile) {
        final file = File(outPath);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(entry.content as List<int>, flush: true);
        fileCount += 1;
      } else {
        await Directory(outPath).create(recursive: true);
      }
    }

    return fileCount;
  }

  String _normalizePath(String path) {
    var value = path.replaceAll('\\', '/');
    while (value.contains('//')) {
      value = value.replaceAll('//', '/');
    }
    if (Platform.isWindows) {
      value = value.toLowerCase();
    }
    return value;
  }

  Future<void> _cleanupOldVersions(
    Directory versionsDir, {
    required int keep,
  }) async {
    if (!await versionsDir.exists()) return;

    final dirs = await versionsDir
        .list()
        .where((e) => e is Directory && !e.path.contains('._installing_'))
        .cast<Directory>()
        .toList();

    if (dirs.length <= keep) return;

    dirs.sort((a, b) {
      final aStat = a.statSync();
      final bStat = b.statSync();
      return bStat.modified.compareTo(aStat.modified);
    });

    for (var i = keep; i < dirs.length; i++) {
      await dirs[i].delete(recursive: true);
    }
  }
}

class _BucketContentItem {
  const _BucketContentItem({
    required this.key,
    required this.sizeBytes,
    required this.lastModified,
  });

  final String key;
  final int? sizeBytes;
  final DateTime? lastModified;
}
