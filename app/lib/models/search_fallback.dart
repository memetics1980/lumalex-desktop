import 'dart:math';

const _irregularForms = <String, String>{
  'am': 'be',
  'are': 'be',
  'was': 'be',
  'were': 'be',
  'been': 'be',
  'went': 'go',
  'gone': 'go',
  'did': 'do',
  'done': 'do',
  'had': 'have',
  'has': 'have',
  'children': 'child',
  'men': 'man',
  'women': 'woman',
  'mice': 'mouse',
  'geese': 'goose',
  'feet': 'foot',
  'teeth': 'tooth',
  'better': 'good',
  'best': 'good',
  'worse': 'bad',
  'worst': 'bad',
};

List<String> morphologicalFallbacks(String rawQuery) {
  final word = rawQuery.trim().toLowerCase();
  if (!RegExp(r"^[a-z]+(?:['’]s)?$").hasMatch(word)) {
    return const [];
  }
  final candidates = <String>[];
  void add(String value) {
    if (value.length >= 2 && value != word && !candidates.contains(value)) {
      candidates.add(value);
    }
  }

  final irregular = _irregularForms[word];
  if (irregular != null) add(irregular);
  if ((word.endsWith("'s") || word.endsWith('’s')) && word.length > 3) {
    final base = word.substring(0, word.length - 2);
    add(base);
    for (final candidate in morphologicalFallbacks(base)) {
      add(candidate);
    }
    return candidates;
  }
  if (word.endsWith('ies') && word.length > 4) {
    add('${word.substring(0, word.length - 3)}y');
  }
  if (word.endsWith('ied') && word.length > 4) {
    add('${word.substring(0, word.length - 3)}y');
  }
  if (word.endsWith('ing') && word.length > 5) {
    final stem = word.substring(0, word.length - 3);
    add(stem);
    add('${stem}e');
    if (_endsWithDoubleConsonant(stem)) add(stem.substring(0, stem.length - 1));
  }
  if (word.endsWith('ed') && word.length > 4) {
    final stem = word.substring(0, word.length - 2);
    add(stem);
    add('${stem}e');
    if (_endsWithDoubleConsonant(stem)) add(stem.substring(0, stem.length - 1));
  }
  if (word.endsWith('iest') && word.length > 5) {
    add('${word.substring(0, word.length - 4)}y');
  } else if (word.endsWith('est') && word.length > 5) {
    _addDegreeFallbacks(word.substring(0, word.length - 3), add);
  }
  if (word.endsWith('ier') && word.length > 4) {
    add('${word.substring(0, word.length - 3)}y');
  } else if (word.endsWith('er') && word.length > 4) {
    _addDegreeFallbacks(word.substring(0, word.length - 2), add);
  }
  if (word.endsWith('es') && word.length > 4) {
    add(word.substring(0, word.length - 2));
  }
  if (word.endsWith('s') && !word.endsWith('ss') && word.length > 3) {
    add(word.substring(0, word.length - 1));
  }
  return candidates;
}

List<String> spellingSearchPrefixes(String rawQuery) {
  final word = rawQuery.trim().toLowerCase();
  if (!RegExp(r'^[a-z]{3,}$').hasMatch(word)) {
    return const [];
  }
  final prefixes = <String>[];
  void add(String value) {
    if (value.length >= 2 && !prefixes.contains(value)) prefixes.add(value);
  }

  for (var index = 0; index < word.length - 1 && prefixes.length < 4; index++) {
    final chars = word.split('');
    final current = chars[index];
    chars[index] = chars[index + 1];
    chars[index + 1] = current;
    add(chars.join());
  }
  add(word.substring(0, max(2, word.length - 1)));
  add(word.substring(0, max(2, word.length - 2)));
  add(word.substring(0, min(3, word.length)));
  return prefixes.take(7).toList(growable: false);
}

List<String> rankSpellingCandidates(
  String rawQuery,
  Iterable<String> suggestions, {
  int limit = 5,
}) {
  final query = rawQuery.trim().toLowerCase();
  if (query.isEmpty || limit <= 0) return const [];
  final threshold = query.length <= 4 ? 1 : (query.length <= 8 ? 2 : 3);
  final ranked = <({String word, int distance})>[];
  final seen = <String>{};
  for (final suggestion in suggestions) {
    final word = suggestion.trim().toLowerCase();
    if (word == query ||
        !seen.add(word) ||
        !RegExp(r'^[a-z]+$').hasMatch(word) ||
        (word.length - query.length).abs() > threshold) {
      continue;
    }
    final distance = _spellingDistance(query, word);
    if (distance <= threshold) ranked.add((word: word, distance: distance));
  }
  ranked.sort((left, right) {
    var order = left.distance.compareTo(right.distance);
    if (order != 0) return order;
    order = left.word.length.compareTo(right.word.length);
    if (order != 0) return order;
    return left.word.compareTo(right.word);
  });
  return ranked.map((entry) => entry.word).take(limit).toList(growable: false);
}

int _spellingDistance(String left, String right) {
  final rows = left.length + 1;
  final columns = right.length + 1;
  final distances = List.generate(
    rows,
    (row) => List<int>.generate(columns, (column) {
      if (row == 0) return column;
      if (column == 0) return row;
      return 0;
    }),
  );
  for (var row = 1; row < rows; row++) {
    for (var column = 1; column < columns; column++) {
      final substitutionCost =
          left.codeUnitAt(row - 1) == right.codeUnitAt(column - 1) ? 0 : 1;
      var distance = min(
        min(
          distances[row - 1][column] + 1,
          distances[row][column - 1] + 1,
        ),
        distances[row - 1][column - 1] + substitutionCost,
      );
      if (row > 1 &&
          column > 1 &&
          left.codeUnitAt(row - 1) == right.codeUnitAt(column - 2) &&
          left.codeUnitAt(row - 2) == right.codeUnitAt(column - 1)) {
        distance = min(distance, distances[row - 2][column - 2] + 1);
      }
      distances[row][column] = distance;
    }
  }
  return distances.last.last;
}

int levenshteinDistance(String left, String right) {
  if (left == right) return 0;
  if (left.isEmpty) return right.length;
  if (right.isEmpty) return left.length;
  var previous = List<int>.generate(right.length + 1, (index) => index);
  for (var leftIndex = 0; leftIndex < left.length; leftIndex++) {
    final current = <int>[leftIndex + 1];
    for (var rightIndex = 0; rightIndex < right.length; rightIndex++) {
      final substitution = previous[rightIndex] +
          (left.codeUnitAt(leftIndex) == right.codeUnitAt(rightIndex) ? 0 : 1);
      current.add(min(
        min(current[rightIndex] + 1, previous[rightIndex + 1] + 1),
        substitution,
      ));
    }
    previous = current;
  }
  return previous.last;
}

bool _endsWithDoubleConsonant(String word) {
  if (word.length < 2 || word[word.length - 1] != word[word.length - 2]) {
    return false;
  }
  return !'aeiou'.contains(word[word.length - 1]);
}

void _addDegreeFallbacks(String stem, void Function(String) add) {
  if (_endsWithDoubleConsonant(stem)) {
    add(stem.substring(0, stem.length - 1));
  }
  // larger -> large, nicer -> nice. Each candidate is still validated by an
  // exact MDX lookup, so a guessed spelling can never become visible itself.
  add('${stem}e');
  add(stem);
}
