import 'dart:collection';
import 'dart:io';

class DictionaryFolderScanResult {
  const DictionaryFolderScanResult({
    required this.mdxPaths,
    required this.unreadableDirectoryCount,
  });

  final List<String> mdxPaths;
  final int unreadableDirectoryCount;
}

/// Finds every MDX dictionary below [rootPath] without following symbolic
/// links. Unreadable child folders are skipped so one damaged folder does not
/// prevent the rest of a dictionary collection from being imported.
Future<DictionaryFolderScanResult> scanDictionaryFolder(
  String rootPath,
) async {
  final pending = Queue<Directory>()..add(Directory(rootPath));
  final mdxPaths = <String>[];
  var unreadableDirectoryCount = 0;

  while (pending.isNotEmpty) {
    final directory = pending.removeFirst();
    final children = <FileSystemEntity>[];
    try {
      await for (final child in directory.list(followLinks: false)) {
        children.add(child);
      }
    } on FileSystemException {
      unreadableDirectoryCount++;
      continue;
    }

    for (final child in children) {
      if (child is Directory) {
        pending.add(child);
      } else if (child is File && child.path.toLowerCase().endsWith('.mdx')) {
        mdxPaths.add(child.absolute.path);
      }
    }
  }

  mdxPaths
      .sort((left, right) => left.toLowerCase().compareTo(right.toLowerCase()));
  return DictionaryFolderScanResult(
    mdxPaths: List.unmodifiable(mdxPaths),
    unreadableDirectoryCount: unreadableDirectoryCount,
  );
}
