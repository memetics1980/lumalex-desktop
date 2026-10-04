String? adjacentDictionaryResultPath({
  required Iterable<String> orderedMdxPaths,
  required Set<String> resultMdxPaths,
  required String? selectedMdxPath,
  required bool forward,
}) {
  final paths = orderedMdxPaths.toList(growable: false);
  if (paths.isEmpty || resultMdxPaths.isEmpty) return null;

  final selectedIndex = selectedMdxPath == null
      ? -1
      : paths.indexWhere((path) => path == selectedMdxPath);
  if (selectedIndex < 0) {
    final candidates = forward ? paths : paths.reversed;
    return candidates.where(resultMdxPaths.contains).firstOrNull;
  }

  var index = selectedIndex + (forward ? 1 : -1);
  while (index >= 0 && index < paths.length) {
    final path = paths[index];
    if (resultMdxPaths.contains(path)) return path;
    index += forward ? 1 : -1;
  }
  return null;
}
