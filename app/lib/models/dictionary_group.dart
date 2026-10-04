import 'dictionary_library_entry.dart';

abstract final class DictionaryGroupScope {
  static const all = '__all__';
  static const ungrouped = '__ungrouped__';

  static bool isSystem(String value) => value == all || value == ungrouped;
}

class DictionaryGroup {
  static const colorChoiceCount = 6;

  const DictionaryGroup({
    required this.id,
    required this.name,
    required this.sortOrder,
    this.colorIndex = 0,
  });

  final String id;
  final String name;
  final int sortOrder;
  final int colorIndex;

  DictionaryGroup copyWith({
    String? name,
    int? sortOrder,
    int? colorIndex,
  }) =>
      DictionaryGroup(
        id: id,
        name: name ?? this.name,
        sortOrder: sortOrder ?? this.sortOrder,
        colorIndex: colorIndex ?? this.colorIndex,
      );

  Map<String, Object> toJson() => <String, Object>{
        'id': id,
        'name': name,
        'sortOrder': sortOrder,
        'colorIndex': colorIndex,
      };

  static DictionaryGroup? fromJson(Object? value) {
    if (value is! Map<Object?, Object?>) return null;
    final id = value['id'];
    final name = value['name'];
    final sortOrder = value['sortOrder'];
    final rawColorIndex = value['colorIndex'];
    if (id is! String ||
        id.isEmpty ||
        DictionaryGroupScope.isSystem(id) ||
        name is! String ||
        name.trim().isEmpty ||
        sortOrder is! int) {
      return null;
    }
    return DictionaryGroup(
      id: id,
      name: name.trim(),
      sortOrder: sortOrder,
      colorIndex: rawColorIndex is int &&
              rawColorIndex >= 0 &&
              rawColorIndex < colorChoiceCount
          ? rawColorIndex
          : 0,
    );
  }
}

class DictionaryGroupSnapshot {
  const DictionaryGroupSnapshot({
    this.groups = const [],
    this.activeScopeId = DictionaryGroupScope.all,
  });

  final List<DictionaryGroup> groups;
  final String activeScopeId;

  DictionaryGroupSnapshot copyWith({
    List<DictionaryGroup>? groups,
    String? activeScopeId,
  }) =>
      DictionaryGroupSnapshot(
        groups: groups ?? this.groups,
        activeScopeId: activeScopeId ?? this.activeScopeId,
      );

  Map<String, Object> toJson() => <String, Object>{
        'groups': groups.map((group) => group.toJson()).toList(growable: false),
        'activeScopeId': activeScopeId,
      };

  static DictionaryGroupSnapshot fromJson(Object? value) {
    if (value is! Map<Object?, Object?>) {
      return const DictionaryGroupSnapshot();
    }
    final groups = (value['groups'] is List<Object?>
            ? value['groups'] as List<Object?>
            : const <Object?>[])
        .map(DictionaryGroup.fromJson)
        .whereType<DictionaryGroup>()
        .toList(growable: false)
      ..sort((left, right) => left.sortOrder.compareTo(right.sortOrder));
    final ids = groups.map((group) => group.id).toSet();
    final storedScope = value['activeScopeId'];
    final activeScopeId = storedScope is String &&
            (DictionaryGroupScope.isSystem(storedScope) ||
                ids.contains(storedScope))
        ? storedScope
        : DictionaryGroupScope.all;
    return DictionaryGroupSnapshot(
      groups: List.unmodifiable(groups),
      activeScopeId: activeScopeId,
    );
  }
}

List<DictionaryLibraryEntry> dictionaryEntriesForScope(
  Iterable<DictionaryLibraryEntry> entries,
  String scopeId,
) =>
    entries.where((entry) {
      if (scopeId == DictionaryGroupScope.all) return true;
      if (scopeId == DictionaryGroupScope.ungrouped) {
        return entry.groupId == null;
      }
      return entry.groupId == scopeId;
    }).toList(growable: false);
