class DictionarySidecarResource {
  const DictionarySidecarResource({
    required this.uri,
    required this.relativePath,
  });

  /// Android Storage Access Framework URI for the original publisher asset.
  final String uri;

  /// Resource path relative to the MDX file. This is retained so linked CSS
  /// and fonts keep exactly the URLs encoded by the dictionary publisher.
  final String relativePath;

  Map<String, Object> toJson() => <String, Object>{
        'uri': uri,
        'relativePath': relativePath,
      };

  static DictionarySidecarResource? fromJson(Object? value) {
    if (value is! Map<Object?, Object?>) {
      return null;
    }
    final uri = value['uri'];
    final relativePath = value['relativePath'];
    if (uri is! String ||
        uri.isEmpty ||
        relativePath is! String ||
        !_isSafeRelativePath(relativePath)) {
      return null;
    }
    return DictionarySidecarResource(uri: uri, relativePath: relativePath);
  }

  static bool _isSafeRelativePath(String value) {
    if (value.isEmpty || value.startsWith('/') || value.contains('\\')) {
      return false;
    }
    return value.split('/').every(
          (segment) => segment.isNotEmpty && segment != '.' && segment != '..',
        );
  }
}

class DictionaryLibraryEntry {
  const DictionaryLibraryEntry({
    required this.title,
    required this.mdxPath,
    required this.importedAtMilliseconds,
    String? accessPath,
    this.sourceRelativePath,
    this.sourceVersion,
    this.contentFingerprint,
    this.mddPaths = const [],
    this.sidecarResources = const [],
    this.isEnabled = true,
    this.groupId,
  }) : accessPath = accessPath ?? mdxPath;

  final String title;
  final String mdxPath;

  /// The sandbox-scoped path that permits reading the MDX and its MDD sidecars.
  final String accessPath;

  /// Stable path inside an Android SAF tree. Document URIs may be regenerated
  /// by a provider after the user authorizes the same folder again; this path
  /// lets LumaLex rebind the existing library row without losing its settings.
  final String? sourceRelativePath;

  /// Provider size/timestamp tuple used only to avoid re-hashing an unchanged
  /// MDX. It is never treated as a dictionary identity.
  final String? sourceVersion;

  /// SHA-256 of the MDX bytes. Unlike a URI, file name, or package title this
  /// remains the same when an identical dictionary is copied or renamed.
  final String? contentFingerprint;

  /// MDD locations explicitly returned by Android's Storage Access Framework.
  /// Desktop platforms discover sidecars from the MDX folder and leave this
  /// empty. Keeping the URIs here lets Android restore the same original files
  /// after the process is restarted, without copying dictionary data.
  final List<String> mddPaths;

  /// Approved stylesheet, script, and font files supplied beside the MDX.
  /// Android stores their original SAF URIs rather than copying their bytes.
  final List<DictionarySidecarResource> sidecarResources;
  final int importedAtMilliseconds;

  /// Whether this dictionary appears in the lookup bar and participates in
  /// multi-dictionary searches.
  final bool isEnabled;

  /// Stable user-created collection identifier. A null value means the
  /// dictionary is shown in the virtual “未分组” collection.
  final String? groupId;

  DictionaryLibraryEntry copyWith({
    String? title,
    String? mdxPath,
    String? accessPath,
    String? sourceRelativePath,
    String? sourceVersion,
    String? contentFingerprint,
    bool clearContentFingerprint = false,
    List<String>? mddPaths,
    List<DictionarySidecarResource>? sidecarResources,
    int? importedAtMilliseconds,
    bool? isEnabled,
    String? groupId,
    bool clearGroupId = false,
  }) =>
      DictionaryLibraryEntry(
        title: title ?? this.title,
        mdxPath: mdxPath ?? this.mdxPath,
        accessPath: accessPath ?? this.accessPath,
        sourceRelativePath: sourceRelativePath ?? this.sourceRelativePath,
        sourceVersion: sourceVersion ?? this.sourceVersion,
        contentFingerprint: clearContentFingerprint
            ? null
            : contentFingerprint ?? this.contentFingerprint,
        mddPaths: mddPaths ?? this.mddPaths,
        sidecarResources: sidecarResources ?? this.sidecarResources,
        importedAtMilliseconds:
            importedAtMilliseconds ?? this.importedAtMilliseconds,
        isEnabled: isEnabled ?? this.isEnabled,
        groupId: clearGroupId ? null : groupId ?? this.groupId,
      );

  Map<String, Object> toJson() => <String, Object>{
        'title': title,
        'mdxPath': mdxPath,
        'accessPath': accessPath,
        if (sourceRelativePath != null)
          'sourceRelativePath': sourceRelativePath!,
        if (sourceVersion != null) 'sourceVersion': sourceVersion!,
        if (contentFingerprint != null)
          'contentFingerprint': contentFingerprint!,
        'mddPaths': mddPaths,
        'sidecarResources': sidecarResources
            .map((resource) => resource.toJson())
            .toList(growable: false),
        'importedAtMilliseconds': importedAtMilliseconds,
        'isEnabled': isEnabled,
        if (groupId != null) 'groupId': groupId!,
      };

  static DictionaryLibraryEntry? fromJson(Object? value) {
    if (value is! Map<Object?, Object?>) {
      return null;
    }

    final title = value['title'];
    final mdxPath = value['mdxPath'];
    final accessPath = value['accessPath'];
    final sourceRelativePath = value['sourceRelativePath'];
    final sourceVersion = value['sourceVersion'];
    final contentFingerprint = value['contentFingerprint'];
    final rawMddPaths = value['mddPaths'];
    final rawSidecarResources = value['sidecarResources'];
    final importedAtMilliseconds = value['importedAtMilliseconds'];
    final isEnabled = value['isEnabled'];
    final groupId = value['groupId'];
    if (title is! String ||
        title.trim().isEmpty ||
        mdxPath is! String ||
        mdxPath.isEmpty) {
      return null;
    }
    if (importedAtMilliseconds is! int) {
      return null;
    }

    final mddPaths = rawMddPaths is List<Object?>
        ? rawMddPaths
            .whereType<String>()
            .where((path) => path.isNotEmpty)
            .toList(
              growable: false,
            )
        : const <String>[];
    final sidecarResources = rawSidecarResources is List<Object?>
        ? rawSidecarResources
            .map(DictionarySidecarResource.fromJson)
            .whereType<DictionarySidecarResource>()
            .toList(growable: false)
        : const <DictionarySidecarResource>[];

    return DictionaryLibraryEntry(
      title: title,
      mdxPath: mdxPath,
      accessPath:
          accessPath is String && accessPath.isNotEmpty ? accessPath : mdxPath,
      sourceRelativePath:
          sourceRelativePath is String && sourceRelativePath.isNotEmpty
              ? sourceRelativePath
              : null,
      sourceVersion: sourceVersion is String && sourceVersion.isNotEmpty
          ? sourceVersion
          : null,
      contentFingerprint: contentFingerprint is String &&
              contentFingerprint.startsWith('sha256:')
          ? contentFingerprint
          : null,
      mddPaths: mddPaths,
      sidecarResources: sidecarResources,
      importedAtMilliseconds: importedAtMilliseconds,
      isEnabled: isEnabled is! bool || isEnabled,
      groupId: groupId is String && groupId.isNotEmpty ? groupId : null,
    );
  }
}
