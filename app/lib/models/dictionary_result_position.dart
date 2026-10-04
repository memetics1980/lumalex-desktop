String dictionaryResultPositionLabel(
  Iterable<String> orderedMdxPaths,
  String? selectedMdxPath,
) {
  final paths = orderedMdxPaths.toList(growable: false);
  if (paths.isEmpty) return '0/0';
  final selectedIndex = selectedMdxPath == null
      ? -1
      : paths.indexWhere((path) => path == selectedMdxPath);
  final position = selectedIndex < 0 ? '–' : '${selectedIndex + 1}';
  return '$position/${paths.length}';
}
