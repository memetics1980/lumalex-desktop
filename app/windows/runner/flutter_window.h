#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <sapi.h>
#include <shellapi.h>

#include <memory>
#include <string>

#include "screen_lookup_popup.h"
#include "screen_lookup_service.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void RegisterTextToSpeechChannel();
  void RegisterWindowLifecycleChannel();
  void RegisterScreenLookupChannel();
  bool ConfigureScreenLookup(bool enabled, const std::string& shortcut,
                             std::string* error);
  bool SetShortcutRecording(bool recording, std::string* error);
  void HandleScreenLookupResult(ScreenLookupResult* raw_result);
  void NotifyScreenLookupAction(const std::string& action);
  bool AddTrayIcon();
  void RemoveTrayIcon();
  bool HideWindowToTray();
  void RestoreWindowFromTray();
  void ShowTrayMenu();
  void ShowFirstHideNotification();
  void NotifyWindowLifecycle(const std::string& event);
  void ExitFromTray();
  void TerminateApplication();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      text_to_speech_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_lifecycle_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      screen_lookup_channel_;
  ScreenLookupService screen_lookup_service_;
  std::unique_ptr<ScreenLookupPopup> screen_lookup_popup_;
  ISpVoice* speech_voice_ = nullptr;
  NOTIFYICONDATAW tray_icon_data_{};
  UINT taskbar_created_message_ = 0;
  bool tray_icon_added_ = false;
  bool hide_to_tray_on_close_ = false;
  bool screen_lookup_enabled_ = false;
  bool screen_lookup_hotkey_registered_ = false;
  int screen_lookup_hotkey_id_ = 2;
  UINT screen_lookup_hotkey_modifiers_ = 0;
  UINT screen_lookup_hotkey_key_ = 0;
  bool screen_lookup_shortcut_recording_ = false;
  bool show_first_hide_notification_ = false;
  bool force_exit_ = false;
  std::wstring current_screen_lookup_query_;
  POINT current_screen_lookup_anchor_{};
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
