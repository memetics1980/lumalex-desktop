import 'dart:collection';

import 'article.dart';

class LookupResultCache {
  LookupResultCache({
    this.maximumEntries = 48,
    this.maximumBytes = 12 * 1024 * 1024,
  });

  final int maximumEntries;
  final int maximumBytes;
  final LinkedHashMap<String, _LookupCacheEntry> _entries = LinkedHashMap();
  var _retainedBytes = 0;

  List<Article>? get(String mdxPath, String query) {
    final key = _key(mdxPath, query);
    final entry = _entries.remove(key);
    if (entry != null) {
      _entries[key] = entry;
    }
    return entry?.articles;
  }

  void put(String mdxPath, String query, List<Article> articles) {
    final key = _key(mdxPath, query);
    final previous = _entries.remove(key);
    _retainedBytes -= previous?.estimatedBytes ?? 0;
    final entry = _LookupCacheEntry(List.unmodifiable(articles));
    _entries[key] = entry;
    _retainedBytes += entry.estimatedBytes;
    while (_entries.length > maximumEntries || _retainedBytes > maximumBytes) {
      final removed = _entries.remove(_entries.keys.first);
      _retainedBytes -= removed?.estimatedBytes ?? 0;
    }
  }

  void removeDictionary(String mdxPath) {
    final prefix = '$mdxPath\u{0}';
    final keys = _entries.keys
        .where((key) => key.startsWith(prefix))
        .toList(growable: false);
    for (final key in keys) {
      _retainedBytes -= _entries.remove(key)?.estimatedBytes ?? 0;
    }
  }

  String _key(String mdxPath, String query) =>
      '$mdxPath\u{0}${query.trim().toLowerCase()}';
}

/// Dart strings occupy UTF-16 code units, so account for two bytes per code
/// unit. This is intentionally conservative: a few unusually large entries
/// must not let iOS terminate the app under memory pressure.
class _LookupCacheEntry {
  _LookupCacheEntry(this.articles)
      : estimatedBytes = articles.fold<int>(
          0,
          (total, article) => total + article.html.length * 2,
        );

  final List<Article> articles;
  final int estimatedBytes;
}
