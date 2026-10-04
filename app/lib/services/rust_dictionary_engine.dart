import '../models/article.dart';
import '../src/rust/api/dictionary.dart' as rust;
import 'dictionary_engine.dart';
import 'dictionary_file_access.dart';

/// Production implementation of the UI contract. Dart retains only a path and
/// display metadata; the Rust core opens and decodes the MDX on demand.
final class RustDictionaryEngine implements DictionaryEngine {
  String? _activeMdxPath;
  final DictionaryFileAccess _fileAccess = DictionaryFileAccess();

  @override
  Future<String> importMdx({required String mdxPath, String? mddPath}) async {
    final resolvedPath = await _fileAccess.resolveMdxPath(mdxPath);
    final info = await rust.inspectMdx(mdxPath: resolvedPath);
    _activeMdxPath = mdxPath;
    return info.title;
  }

  @override
  Future<void> ensureIndex({required String mdxPath}) async {
    await rust.ensureMdxIndex(
      mdxPath: await _fileAccess.resolveMdxPath(mdxPath),
    );
  }

  @override
  void clearActiveDictionary() {
    _activeMdxPath = null;
  }

  @override
  Future<List<Article>> lookup(String query, {String? mdxPath}) async {
    final targetMdxPath = mdxPath ?? _activeMdxPath;
    if (targetMdxPath == null) {
      return const [];
    }
    final resolvedPath = await _fileAccess.resolveMdxPath(targetMdxPath);

    final records = await rust.lookupMdx(
      mdxPath: resolvedPath,
      query: query,
    );
    return records
        .map(
          (record) => Article(
            dictionaryName: record.dictionaryName,
            mdxPath: targetMdxPath,
            headword: record.headword,
            html: record.html,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<List<String>> suggest(
    String prefix, {
    required int limit,
    String? mdxPath,
  }) async {
    final targetMdxPath = mdxPath ?? _activeMdxPath;
    if (targetMdxPath == null) {
      return const [];
    }

    return rust.suggestMdx(
      mdxPath: await _fileAccess.resolveMdxPath(targetMdxPath),
      prefix: prefix,
      limit: limit,
    );
  }

  @override
  Future<DictionaryResourceData?> readResource(
    String resourcePath, {
    required int maxBytes,
    String? mdxPath,
  }) async {
    final targetMdxPath = mdxPath ?? _activeMdxPath;
    if (targetMdxPath == null) {
      return null;
    }

    final resource = await rust.readMddResource(
      // Importing and headword lookup only open the MDX. Resolve potentially
      // very large MDD media volumes when a renderer or audio control first
      // needs an attachment instead of making a folder import copy them all.
      mdxPath: await _fileAccess.resolveMdxPathForResources(targetMdxPath),
      resourcePath: resourcePath,
      maxBytes: maxBytes,
    );
    if (resource == null) {
      return null;
    }

    return DictionaryResourceData(
      path: resource.resourcePath,
      mimeType: resource.mimeType,
      bytes: resource.bytes,
    );
  }
}
