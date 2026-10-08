import 'search_fallback.dart';

final class LookupFormMatch<T> {
  const LookupFormMatch(
      {required this.index, required this.values, this.candidate});
  final int index;
  final List<T> values;
  final LookupFormCandidate? candidate;
  bool get exact => candidate == null;
}

/// Complete the original-query pass across the scope before any fallback.
Future<LookupFormMatch<T>?> resolveLookupForms<T>({
  required String query,
  required List<int> indexes,
  required Future<List<T>> Function(int index, String query) lookup,
  required bool Function() isCurrent,
  bool includeExact = true,
  bool includeRelated = true,
}) async {
  Future<LookupFormMatch<T>?> probe(
      String term, LookupFormCandidate? form) async {
    for (final index in indexes) {
      if (!isCurrent()) return null;
      final values = await lookup(index, term);
      if (!isCurrent()) return null;
      if (values.isNotEmpty) {
        return LookupFormMatch(
          index: index,
          values: values,
          candidate: form,
        );
      }
    }
    return null;
  }

  if (includeExact) {
    final exact = await probe(query, null);
    if (!isCurrent() || exact != null) return exact;
  }
  if (!includeRelated) return null;
  for (final form in [
    ...lookupFormCandidates(query),
    ...phraseHeadwordCandidates(query)
  ]) {
    final match = await probe(form.query, form);
    if (!isCurrent() || match != null) return match;
  }
  return null;
}

/// Related forms supplement a successful original lookup; they never replace it.
Future<List<LookupFormMatch<T>>> collectRelatedLookupForms<T>({
  required String query,
  required List<int> indexes,
  required Future<List<T>> Function(int index, String query) lookup,
  required bool Function() isCurrent,
  Set<String> excludeQueries = const {},
  int limit = 3,
}) async {
  final matches = <LookupFormMatch<T>>[];
  if (limit <= 0) return matches;
  for (final candidate in lookupFormCandidates(query)) {
    if (excludeQueries.contains(candidate.query)) continue;
    for (final index in indexes) {
      if (!isCurrent()) return const [];
      final values = await lookup(index, candidate.query);
      if (!isCurrent()) return const [];
      if (values.isNotEmpty) {
        matches.add(LookupFormMatch(
            index: index, values: values, candidate: candidate));
        break;
      }
    }
    if (matches.length >= limit) break;
  }
  return matches;
}
