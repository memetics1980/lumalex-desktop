import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../models/article.dart';

abstract interface class ArticleCacheStore {
  /// [mdxPath] is the stable library identifier. On Android it is usually a
  /// `content://` URI, which cannot be stat'ed as a Dart [File]; callers pass
  /// the already-open, seekable [sourcePath] for cache validation instead.
  Future<List<Article>?> read(
    String mdxPath,
    String query, {
    String? sourcePath,
  });

  Future<void> write(
    String mdxPath,
    String query,
    List<Article> articles, {
    String? sourcePath,
  });
}

/// A disposable, source-bound cache for decoded MDX article HTML. Cache files
/// live under the platform application-cache directory and are invalidated
/// whenever the source MDX size or modification time changes.
final class FileArticleCacheStore implements ArticleCacheStore {
  FileArticleCacheStore(
    this.directory, {
    this.maximumEntries = 1024,
    this.maximumBytes = 128 * 1024 * 1024,
  });

  final Directory directory;
  final int maximumEntries;
  final int maximumBytes;
  Future<void>? _pruneFuture;

  @override
  Future<List<Article>?> read(
    String mdxPath,
    String query, {
    String? sourcePath,
  }) async {
    final cacheFile = _fileFor(mdxPath, query);
    if (!await cacheFile.exists()) {
      return null;
    }
    try {
      final source = await File(sourcePath ?? mdxPath).stat();
      final decoded = jsonDecode(await cacheFile.readAsString());
      if (decoded is! Map<String, Object?> ||
          decoded['version'] != 1 ||
          decoded['mdxPath'] != mdxPath ||
          decoded['sourceBytes'] != source.size ||
          decoded['sourceModifiedMilliseconds'] !=
              source.modified.millisecondsSinceEpoch) {
        await _deleteIfPresent(cacheFile);
        return null;
      }
      final records = decoded['articles'];
      if (records is! List<Object?>) {
        await _deleteIfPresent(cacheFile);
        return null;
      }
      final articles = <Article>[];
      for (final record in records) {
        if (record is! Map<String, Object?> ||
            record['dictionaryName'] is! String ||
            record['headword'] is! String ||
            record['html'] is! String) {
          await _deleteIfPresent(cacheFile);
          return null;
        }
        articles.add(
          Article(
            dictionaryName: record['dictionaryName']! as String,
            mdxPath: mdxPath,
            headword: record['headword']! as String,
            html: record['html']! as String,
          ),
        );
      }
      await cacheFile.setLastModified(DateTime.now());
      return List.unmodifiable(articles);
    } catch (_) {
      await _deleteIfPresent(cacheFile);
      return null;
    }
  }

  @override
  Future<void> write(
    String mdxPath,
    String query,
    List<Article> articles, {
    String? sourcePath,
  }) async {
    try {
      final source = await File(sourcePath ?? mdxPath).stat();
      await directory.create(recursive: true);
      final cacheFile = _fileFor(mdxPath, query);
      final temporary = File(
        '${cacheFile.path}.writing-${DateTime.now().microsecondsSinceEpoch}',
      );
      await temporary.writeAsString(
        jsonEncode(<String, Object?>{
          'version': 1,
          'mdxPath': mdxPath,
          'sourceBytes': source.size,
          'sourceModifiedMilliseconds': source.modified.millisecondsSinceEpoch,
          'query': query.trim(),
          'articles': articles
              .map(
                (article) => <String, String>{
                  'dictionaryName': article.dictionaryName,
                  'headword': article.headword,
                  'html': article.html,
                },
              )
              .toList(growable: false),
        }),
        flush: true,
      );
      try {
        await temporary.rename(cacheFile.path);
      } on FileSystemException {
        await _deleteIfPresent(cacheFile);
        await temporary.rename(cacheFile.path);
      }
      _pruneFuture ??= _prune().whenComplete(() => _pruneFuture = null);
    } catch (_) {
      // A disposable cache must never make a dictionary lookup fail.
    }
  }

  File _fileFor(String mdxPath, String query) {
    final key = '$mdxPath\u{0}${query.trim().toLowerCase()}';
    return File(
      '${directory.path}${Platform.pathSeparator}${sha256.convert(utf8.encode(key))}.json',
    );
  }

  Future<void> _prune() async {
    if (!await directory.exists()) {
      return;
    }
    final files = await directory
        .list()
        .where((entity) => entity is File && entity.path.endsWith('.json'))
        .cast<File>()
        .toList();
    final records = <({File file, FileStat stat})>[];
    for (final file in files) {
      try {
        records.add((file: file, stat: await file.stat()));
      } catch (_) {}
    }
    records.sort(
        (left, right) => right.stat.modified.compareTo(left.stat.modified));
    var retainedBytes = 0;
    for (var index = 0; index < records.length; index++) {
      final record = records[index];
      retainedBytes += record.stat.size;
      if (index >= maximumEntries || retainedBytes > maximumBytes) {
        await _deleteIfPresent(record.file);
      }
    }
  }

  Future<void> _deleteIfPresent(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }
}

final class InMemoryArticleCacheStore implements ArticleCacheStore {
  final Map<String, List<Article>> _entries = {};

  @override
  Future<List<Article>?> read(
    String mdxPath,
    String query, {
    String? sourcePath,
  }) async =>
      _entries[_key(mdxPath, query)];

  @override
  Future<void> write(
    String mdxPath,
    String query,
    List<Article> articles, {
    String? sourcePath,
  }) async {
    _entries[_key(mdxPath, query)] = List.unmodifiable(articles);
  }

  String _key(String mdxPath, String query) =>
      '$mdxPath\u{0}${query.trim().toLowerCase()}';
}
