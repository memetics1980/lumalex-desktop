import 'dart:async';

/// Serializes visibility changes without reloading the reader document.
/// A late pause must never win over a newer restore request.
class ReaderHostVisibility {
  ReaderHostVisibility({required this.onError});

  final void Function(Object error) onError;
  Future<void> Function(bool visible)? _writer;
  Future<void> _pending = Future.value();
  bool _visible = true;
  bool? _applied;

  Future<void> bind(Future<void> Function(bool visible)? writer) {
    _writer = writer;
    _applied = null;
    return _schedule();
  }

  Future<void> setVisible(bool visible) {
    _visible = visible;
    return _schedule();
  }

  Future<void> _schedule() {
    return _pending = _pending.then((_) async {
      final writer = _writer;
      final visible = _visible;
      if (writer == null || _applied == visible) return;
      try {
        await writer(visible);
        if (identical(writer, _writer)) _applied = visible;
      } catch (error) {
        onError(error);
      }
    });
  }
}
