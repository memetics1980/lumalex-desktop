import 'dart:collection';

/// A small LRU of per-word, per-dictionary reading positions.
///
/// Retaining offsets separately from WKWebView lifetime lets an evicted iOS
/// reader return to the same paragraph when its fixed native slot is reused.
class ReaderPositionCache {
  ReaderPositionCache({this.maximumEntries = 96});

  final int maximumEntries;
  final LinkedHashMap<String, double> _offsets = LinkedHashMap();

  double? get(String mdxPath, String query) {
    final key = _key(mdxPath, query);
    final offset = _offsets.remove(key);
    if (offset != null) _offsets[key] = offset;
    return offset;
  }

  void put(String mdxPath, String query, double offset) {
    final normalizedQuery = query.trim();
    if (mdxPath.isEmpty ||
        normalizedQuery.isEmpty ||
        !offset.isFinite ||
        offset < 0 ||
        maximumEntries <= 0) {
      return;
    }
    final key = _key(mdxPath, normalizedQuery);
    _offsets.remove(key);
    _offsets[key] = offset;
    while (_offsets.length > maximumEntries) {
      _offsets.remove(_offsets.keys.first);
    }
  }

  void removeDictionary(String mdxPath) {
    final prefix = '$mdxPath\u{0}';
    _offsets.removeWhere((key, _) => key.startsWith(prefix));
  }

  void clear() => _offsets.clear();

  String _key(String mdxPath, String query) =>
      '$mdxPath\u{0}${query.trim().toLowerCase()}';
}
