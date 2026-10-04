import 'dart:io';

import 'package:path_provider/path_provider.dart';

typedef DocumentsDirectoryProvider = Future<Directory> Function();

/// Owns the user-visible dictionary folder inside the iOS app container.
///
/// With iOS file sharing enabled, the application's Documents directory is
/// represented by the LumaLex folder in Files. Keeping dictionaries in a
/// child directory prevents user-managed sources from mixing with future
/// document types while indexes and caches remain in private Library folders.
class IosDictionaryHome {
  IosDictionaryHome({
    DocumentsDirectoryProvider? documentsDirectoryProvider,
    bool? isIos,
  })  : _documentsDirectoryProvider =
            documentsDirectoryProvider ?? getApplicationDocumentsDirectory,
        _isIos = isIos ?? Platform.isIOS;

  static const directoryName = 'Dictionaries';
  static const displayPath = '文件 > 我的 iPhone/iPad > LumaLex > Dictionaries';

  final DocumentsDirectoryProvider _documentsDirectoryProvider;
  final bool _isIos;

  Future<Directory?> ensureExists() async {
    if (!_isIos) {
      return null;
    }
    final documentsDirectory = await _documentsDirectoryProvider();
    final directory = Directory(
      '${documentsDirectory.path}${Platform.pathSeparator}$directoryName',
    );
    await directory.create(recursive: true);
    return directory;
  }

  /// Deletes only a newly created, direct child of LumaLex/Dictionaries.
  /// This is used when a provider could not grant a durable bookmark, iOS
  /// copied the selected folder into the app, and every MDX in that copy was
  /// subsequently proven to be an exact duplicate. Resolving both paths first
  /// prevents a malformed path or symlink from widening the deletion scope.
  Future<bool> removeRedundantCopiedImport(String path) async {
    if (!_isIos) return false;
    final home = await ensureExists();
    if (home == null) return false;
    final candidate = Directory(path);
    if (!await candidate.exists()) return false;
    final resolvedHome = await home.resolveSymbolicLinks();
    final resolvedCandidate = await candidate.resolveSymbolicLinks();
    if (Directory(resolvedCandidate).parent.path != resolvedHome) return false;
    await candidate.delete(recursive: true);
    return true;
  }
}
