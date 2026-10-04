import 'package:shared_preferences/shared_preferences.dart';

import '../platform/windows_screen_lookup.dart';
import 'screen_lookup_ai.dart';

enum WindowsCloseBehavior {
  exitApp,
  hideToTray,
}

WindowsCloseBehavior windowsCloseBehaviorFromStorage(String? value) =>
    value == WindowsCloseBehavior.hideToTray.name
        ? WindowsCloseBehavior.hideToTray
        : WindowsCloseBehavior.exitApp;

abstract interface class WindowsAppSettingsStore {
  Future<WindowsCloseBehavior> loadCloseBehavior();

  Future<void> saveCloseBehavior(WindowsCloseBehavior behavior);

  Future<bool> loadTrayNotificationShown();

  Future<void> saveTrayNotificationShown(bool shown);

  Future<bool> loadScreenLookupEnabled();

  Future<void> saveScreenLookupEnabled(bool enabled);

  Future<WindowsScreenLookupShortcut> loadScreenLookupShortcut();

  Future<void> saveScreenLookupShortcut(
    WindowsScreenLookupShortcut shortcut,
  );

  Future<bool> loadScreenLookupAiEnabled();

  Future<void> saveScreenLookupAiEnabled(bool enabled);

  Future<String> loadScreenLookupAiBaseUrl();

  Future<void> saveScreenLookupAiBaseUrl(String baseUrl);

  Future<String> loadScreenLookupAiModel();

  Future<void> saveScreenLookupAiModel(String model);
}

class PreferencesWindowsAppSettingsStore implements WindowsAppSettingsStore {
  PreferencesWindowsAppSettingsStore([SharedPreferencesAsync? preferences])
      : _preferences = preferences ?? SharedPreferencesAsync();

  static const _closeBehaviorKey = 'local_dictionary.windows.close_behavior.v1';
  static const _trayNotificationShownKey =
      'local_dictionary.windows.tray_notification_shown.v1';
  static const _screenLookupEnabledKey =
      'local_dictionary.windows.screen_lookup_enabled.v1';
  static const _screenLookupShortcutKey =
      'local_dictionary.windows.screen_lookup_shortcut.v1';
  static const _screenLookupAiEnabledKey =
      'local_dictionary.windows.screen_lookup_ai_enabled.v1';
  static const _screenLookupAiBaseUrlKey =
      'local_dictionary.windows.screen_lookup_ai_base_url.v1';
  static const _screenLookupAiModelKey =
      'local_dictionary.windows.screen_lookup_ai_model.v1';

  final SharedPreferencesAsync _preferences;

  @override
  Future<WindowsCloseBehavior> loadCloseBehavior() async =>
      windowsCloseBehaviorFromStorage(
        await _preferences.getString(_closeBehaviorKey),
      );

  @override
  Future<void> saveCloseBehavior(WindowsCloseBehavior behavior) =>
      _preferences.setString(_closeBehaviorKey, behavior.name);

  @override
  Future<bool> loadTrayNotificationShown() async =>
      await _preferences.getBool(_trayNotificationShownKey) ?? false;

  @override
  Future<void> saveTrayNotificationShown(bool shown) =>
      _preferences.setBool(_trayNotificationShownKey, shown);

  @override
  Future<bool> loadScreenLookupEnabled() async =>
      await _preferences.getBool(_screenLookupEnabledKey) ?? false;

  @override
  Future<void> saveScreenLookupEnabled(bool enabled) =>
      _preferences.setBool(_screenLookupEnabledKey, enabled);

  @override
  Future<WindowsScreenLookupShortcut> loadScreenLookupShortcut() async =>
      windowsScreenLookupShortcutFromStorage(
        await _preferences.getString(_screenLookupShortcutKey),
      );

  @override
  Future<void> saveScreenLookupShortcut(
    WindowsScreenLookupShortcut shortcut,
  ) =>
      _preferences.setString(_screenLookupShortcutKey, shortcut.name);

  @override
  Future<bool> loadScreenLookupAiEnabled() async =>
      await _preferences.getBool(_screenLookupAiEnabledKey) ?? false;

  @override
  Future<void> saveScreenLookupAiEnabled(bool enabled) =>
      _preferences.setBool(_screenLookupAiEnabledKey, enabled);

  @override
  Future<String> loadScreenLookupAiBaseUrl() async =>
      await _preferences.getString(_screenLookupAiBaseUrlKey) ??
      defaultScreenLookupAiBaseUrl;

  @override
  Future<void> saveScreenLookupAiBaseUrl(String baseUrl) =>
      _preferences.setString(_screenLookupAiBaseUrlKey, baseUrl);

  @override
  Future<String> loadScreenLookupAiModel() async =>
      await _preferences.getString(_screenLookupAiModelKey) ?? '';

  @override
  Future<void> saveScreenLookupAiModel(String model) =>
      _preferences.setString(_screenLookupAiModelKey, model);
}

class InMemoryWindowsAppSettingsStore implements WindowsAppSettingsStore {
  InMemoryWindowsAppSettingsStore({
    this.closeBehavior = WindowsCloseBehavior.exitApp,
    this.trayNotificationShown = false,
    this.screenLookupEnabled = false,
    this.screenLookupShortcut = WindowsScreenLookupShortcut.ctrlAltL,
    this.screenLookupAiEnabled = false,
    this.screenLookupAiBaseUrl = defaultScreenLookupAiBaseUrl,
    this.screenLookupAiModel = '',
  });

  WindowsCloseBehavior closeBehavior;
  bool trayNotificationShown;
  bool screenLookupEnabled;
  WindowsScreenLookupShortcut screenLookupShortcut;
  bool screenLookupAiEnabled;
  String screenLookupAiBaseUrl;
  String screenLookupAiModel;

  @override
  Future<WindowsCloseBehavior> loadCloseBehavior() async => closeBehavior;

  @override
  Future<void> saveCloseBehavior(WindowsCloseBehavior behavior) async {
    closeBehavior = behavior;
  }

  @override
  Future<bool> loadTrayNotificationShown() async => trayNotificationShown;

  @override
  Future<void> saveTrayNotificationShown(bool shown) async {
    trayNotificationShown = shown;
  }

  @override
  Future<bool> loadScreenLookupEnabled() async => screenLookupEnabled;

  @override
  Future<void> saveScreenLookupEnabled(bool enabled) async {
    screenLookupEnabled = enabled;
  }

  @override
  Future<WindowsScreenLookupShortcut> loadScreenLookupShortcut() async =>
      screenLookupShortcut;

  @override
  Future<void> saveScreenLookupShortcut(
    WindowsScreenLookupShortcut shortcut,
  ) async {
    screenLookupShortcut = shortcut;
  }

  @override
  Future<bool> loadScreenLookupAiEnabled() async => screenLookupAiEnabled;

  @override
  Future<void> saveScreenLookupAiEnabled(bool enabled) async {
    screenLookupAiEnabled = enabled;
  }

  @override
  Future<String> loadScreenLookupAiBaseUrl() async => screenLookupAiBaseUrl;

  @override
  Future<void> saveScreenLookupAiBaseUrl(String baseUrl) async {
    screenLookupAiBaseUrl = baseUrl;
  }

  @override
  Future<String> loadScreenLookupAiModel() async => screenLookupAiModel;

  @override
  Future<void> saveScreenLookupAiModel(String model) async {
    screenLookupAiModel = model;
  }
}
