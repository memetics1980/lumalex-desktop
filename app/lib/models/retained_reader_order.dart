/// Returns retained dictionary readers in stable library order.
///
/// [retainedLruPaths] controls membership and eviction, but must not control
/// widget order. Reordering Android platform-view children on every selection
/// can detach and recreate their native surfaces even when their Flutter keys
/// are unchanged.
List<String> retainedReaderDisplayOrder({
  required Iterable<String> libraryPaths,
  required Iterable<String> retainedLruPaths,
  required String selectedPath,
}) {
  final visiblePaths = retainedLruPaths.toSet()..add(selectedPath);
  return libraryPaths.where(visiblePaths.contains).toList(growable: false);
}

/// Shrinks an LRU list while guaranteeing that the selected reader survives.
List<String> trimRetainedReaderLru({
  required Iterable<String> retainedLruPaths,
  required String? selectedPath,
  required int maximumReaders,
}) {
  final limit = maximumReaders < 1 ? 1 : maximumReaders;
  final paths = <String>[];
  for (final path in retainedLruPaths) {
    paths.remove(path);
    paths.add(path);
  }
  if (selectedPath != null) {
    paths.remove(selectedPath);
    paths.add(selectedPath);
  }
  if (paths.length <= limit) return paths;
  return paths.sublist(paths.length - limit);
}
