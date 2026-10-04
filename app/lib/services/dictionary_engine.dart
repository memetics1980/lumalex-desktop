import 'dart:typed_data';

import '../models/article.dart';

/// UI-facing API. The Rust bridge will implement this contract, keeping all
/// MDX/MDD details out of widgets and state management.
abstract interface class DictionaryEngine {
  Future<List<Article>> lookup(String query, {String? mdxPath});

  Future<List<String>> suggest(
    String prefix, {
    required int limit,
    String? mdxPath,
  });

  Future<String> importMdx({required String mdxPath, String? mddPath});

  /// Builds or reuses a disposable on-disk headword index. Implementations
  /// must leave the source MDX untouched.
  Future<void> ensureIndex({required String mdxPath});

  void clearActiveDictionary();

  /// Resolves an MDD attachment for the active dictionary. Callers must keep
  /// the limit small because dictionary files are untrusted local input.
  Future<DictionaryResourceData?> readResource(
    String resourcePath, {
    required int maxBytes,
    String? mdxPath,
  });
}

class DictionaryResourceData {
  const DictionaryResourceData({
    required this.path,
    required this.mimeType,
    required this.bytes,
  });

  final String path;
  final String mimeType;
  final Uint8List bytes;
}

/// Allows the UI to run before the generated Rust bridge is connected.
/// It intentionally returns no demo definitions: a dictionary app should never
/// make test data look like a genuine lookup result.
final class UnavailableDictionaryEngine implements DictionaryEngine {
  const UnavailableDictionaryEngine();

  @override
  Future<String> importMdx({required String mdxPath, String? mddPath}) {
    return Future<String>.error(
      UnsupportedError(
        'The local Rust dictionary bridge is not connected yet.',
      ),
    );
  }

  @override
  Future<void> ensureIndex({required String mdxPath}) async {}

  @override
  void clearActiveDictionary() {}

  @override
  Future<List<String>> suggest(
    String prefix, {
    required int limit,
    String? mdxPath,
  }) async =>
      const [];

  @override
  Future<DictionaryResourceData?> readResource(
    String resourcePath, {
    required int maxBytes,
    String? mdxPath,
  }) async =>
      null;

  @override
  Future<List<Article>> lookup(String query, {String? mdxPath}) async =>
      const [];
}
