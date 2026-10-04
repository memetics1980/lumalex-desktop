class LookupLocation {
  const LookupLocation({
    required this.query,
    required this.mdxPath,
    required this.scrollOffset,
  });

  final String query;
  final String mdxPath;
  final double scrollOffset;
}

class LookupNavigationHistory {
  LookupNavigationHistory({this.maximumEntries = 100});

  final int maximumEntries;
  final List<LookupLocation> _back = [];
  final List<LookupLocation> _forward = [];

  bool get canGoBack => _back.isNotEmpty;
  bool get canGoForward => _forward.isNotEmpty;

  void recordDeparture(LookupLocation location) {
    _back.add(location);
    if (_back.length > maximumEntries) {
      _back.removeAt(0);
    }
    _forward.clear();
  }

  LookupLocation? goBackFrom(LookupLocation current) {
    if (_back.isEmpty) {
      return null;
    }
    _forward.add(current);
    return _back.removeLast();
  }

  LookupLocation? goForwardFrom(LookupLocation current) {
    if (_forward.isEmpty) {
      return null;
    }
    _back.add(current);
    return _forward.removeLast();
  }

  void clear() {
    _back.clear();
    _forward.clear();
  }
}
