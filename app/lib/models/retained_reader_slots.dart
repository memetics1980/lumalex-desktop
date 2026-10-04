/// Keeps retained dictionary paths assigned to stable native-reader slots.
///
/// Paths absent from [retainedLruPaths] release their slot. Existing retained
/// paths never move, and newly retained paths fill the first free slot. This
/// lets iOS replace a document inside one of its two long-lived WKWebViews
/// instead of disposing and recreating a platform view for every LRU miss.
List<String?> assignRetainedReaderSlots({
  required Iterable<String?> currentSlots,
  required Iterable<String> retainedLruPaths,
  required int slotCount,
}) {
  if (slotCount <= 0) return const [];

  final retained = <String>[];
  for (final path in retainedLruPaths) {
    if (path.isEmpty) continue;
    retained.remove(path);
    retained.add(path);
  }
  final boundedRetained = retained.length <= slotCount
      ? retained
      : retained.sublist(retained.length - slotCount);
  final retainedSet = boundedRetained.toSet();
  final slots = List<String?>.filled(slotCount, null);
  final assigned = <String>{};

  var index = 0;
  for (final path in currentSlots) {
    if (index >= slotCount) break;
    if (path != null && retainedSet.contains(path) && assigned.add(path)) {
      slots[index] = path;
    }
    index++;
  }

  for (final path in boundedRetained) {
    if (assigned.contains(path)) continue;
    final freeSlot = slots.indexOf(null);
    if (freeSlot < 0) break;
    slots[freeSlot] = path;
    assigned.add(path);
  }
  return List.unmodifiable(slots);
}
