import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../platform/windows_screen_lookup.dart';

/// Records only while this modal route is open; no app-wide key listener.
class ScreenLookupShortcutDialog extends StatefulWidget {
  const ScreenLookupShortcutDialog({super.key});

  @override
  State<ScreenLookupShortcutDialog> createState() =>
      _ScreenLookupShortcutDialogState();
}

class _ScreenLookupShortcutDialogState
    extends State<ScreenLookupShortcutDialog> {
  final _focus = FocusNode();
  WindowsScreenLookupShortcut? _shortcut;
  String? _error;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _record(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || event.synthesized) {
      return KeyEventResult.handled;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.tab) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if ({
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.controlRight,
      LogicalKeyboardKey.altLeft,
      LogicalKeyboardKey.altRight,
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.shiftRight,
      LogicalKeyboardKey.metaLeft,
      LogicalKeyboardKey.metaRight,
    }.contains(key)) {
      return KeyEventResult.handled;
    }
    final keyboard = HardwareKeyboard.instance;
    final macOS = Platform.isMacOS;
    final modifiers =
        ((macOS ? keyboard.isMetaPressed : keyboard.isControlPressed) ? 2 : 0) |
            (keyboard.isAltPressed ? 1 : 0) |
            (keyboard.isShiftPressed ? 4 : 0);
    final virtualKey = WindowsScreenLookupShortcut.virtualKeyFor(key);
    setState(() {
      _shortcut = null;
      if ((macOS ? keyboard.isControlPressed : keyboard.isMetaPressed) ||
          virtualKey == null ||
          !WindowsScreenLookupShortcut.isValidCombination(
            modifiers,
            virtualKey,
          )) {
        _error = macOS
            ? '请使用 ⌘ 或 ⌥ 搭配字母、数字或 F1–F11；避开复制、粘贴等常用组合。'
            : '请使用 Ctrl 或 Alt 搭配字母、数字或 F1–F11；避开复制、粘贴等常用组合。';
      } else {
        _error = null;
        _shortcut = WindowsScreenLookupShortcut.custom(
          modifiers: modifiers,
          virtualKey: virtualKey,
        );
      }
    });
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('自定义取词快捷键'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('点击下方区域，然后按下你想使用的组合键。'),
              const SizedBox(height: 16),
              Focus(
                focusNode: _focus,
                autofocus: true,
                onKeyEvent: _record,
                child: GestureDetector(
                  onTap: _focus.requestFocus,
                  child: Container(
                    key: const ValueKey('screen-lookup-shortcut-recorder'),
                    width: double.infinity,
                    constraints: const BoxConstraints(minHeight: 64),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(
                          color: Theme.of(context).colorScheme.primary),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(_shortcut?.label ?? '按下组合键…'),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                  _error ??
                      (Platform.isMacOS
                          ? '至少包含 ⌘ 或 ⌥，可加 ⇧。不支持 Control、F12、单键及复制粘贴等常用组合。'
                          : '至少包含 Ctrl 或 Alt，可加 Shift。不支持 Win 键、F12、单键及复制粘贴等常用组合。'),
                  style: TextStyle(
                      color: _error == null
                          ? Theme.of(context).colorScheme.onSurfaceVariant
                          : Theme.of(context).colorScheme.error)),
              const SizedBox(height: 8),
              const Text('录入期间暂停全局取词；按 Esc 或点击取消可退出。'),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消')),
          FilledButton(
            key: const ValueKey('save-screen-lookup-shortcut'),
            onPressed: _shortcut == null
                ? null
                : () => Navigator.of(context).pop(_shortcut),
            child: const Text('使用此快捷键'),
          ),
        ],
      );
}
