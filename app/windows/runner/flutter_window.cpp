#include "flutter_window.h"

#include <flutter/encodable_value.h>

#include <wincred.h>

#include <limits>
#include <optional>
#include <cstdlib>
#include <string>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"
#include "screen_lookup_hotkey.h"

namespace {

constexpr char kTextToSpeechChannel[] = "local_dictionary/text_to_speech";
constexpr char kWindowLifecycleChannel[] =
    "local_dictionary/windows_window_lifecycle";
constexpr char kScreenLookupChannel[] =
    "local_dictionary/windows_screen_lookup";
constexpr wchar_t kAiApiKeyCredentialTarget[] =
    L"LumaLex.ScreenLookupAI.ApiKey";
constexpr UINT kTrayCallbackMessage = WM_APP + 1;
constexpr UINT kScreenLookupReadyMessage = WM_APP + 2;
constexpr UINT kTrayIconId = 1;
constexpr UINT kTrayOpenCommand = 1001;
constexpr UINT kTrayExitCommand = 1002;

std::wstring Utf16FromUtf8(const std::string& value) {
  if (value.empty() ||
      value.size() >
          static_cast<size_t>(std::numeric_limits<int>::max())) {
    return std::wstring();
  }
  const int input_length = static_cast<int>(value.size());
  const int output_length = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), input_length, nullptr, 0);
  if (output_length <= 0) {
    return std::wstring();
  }
  std::wstring output(static_cast<size_t>(output_length), L'\0');
  const int converted = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), input_length, output.data(),
      output_length);
  return converted == output_length ? output : std::wstring();
}

std::string Utf8FromUtf16(const std::wstring& value) {
  if (value.empty() ||
      value.size() > static_cast<size_t>(std::numeric_limits<int>::max())) {
    return std::string();
  }
  const int input_length = static_cast<int>(value.size());
  const int output_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), input_length, nullptr, 0,
      nullptr, nullptr);
  if (output_length <= 0) {
    return std::string();
  }
  std::string output(static_cast<size_t>(output_length), '\0');
  const int converted = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), input_length, output.data(),
      output_length, nullptr, nullptr);
  return converted == output_length ? output : std::string();
}

std::optional<std::wstring> ReadAiApiKeyCredential() {
  PCREDENTIALW credential = nullptr;
  if (!CredReadW(kAiApiKeyCredentialTarget, CRED_TYPE_GENERIC, 0,
                 &credential) ||
      credential == nullptr) {
    return std::nullopt;
  }
  std::wstring secret;
  if (credential->CredentialBlob != nullptr &&
      credential->CredentialBlobSize > 0 &&
      credential->CredentialBlobSize % sizeof(wchar_t) == 0) {
    const auto* value =
        reinterpret_cast<const wchar_t*>(credential->CredentialBlob);
    secret.assign(value,
                  credential->CredentialBlobSize / sizeof(wchar_t));
  }
  CredFree(credential);
  return secret;
}

bool WriteAiApiKeyCredential(const std::wstring& secret) {
  if (secret.empty() || secret.size() > 4096) {
    return false;
  }
  CREDENTIALW credential{};
  credential.Type = CRED_TYPE_GENERIC;
  credential.TargetName =
      const_cast<LPWSTR>(kAiApiKeyCredentialTarget);
  credential.CredentialBlobSize =
      static_cast<DWORD>(secret.size() * sizeof(wchar_t));
  credential.CredentialBlob = reinterpret_cast<LPBYTE>(
      const_cast<wchar_t*>(secret.data()));
  credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
  credential.UserName = const_cast<LPWSTR>(L"LumaLex");
  return CredWriteW(&credential, 0) == TRUE;
}

bool DeleteAiApiKeyCredential() {
  if (CredDeleteW(kAiApiKeyCredentialTarget, CRED_TYPE_GENERIC, 0)) {
    return true;
  }
  return GetLastError() == ERROR_NOT_FOUND;
}

const flutter::EncodableMap* ReadArguments(
    const flutter::MethodCall<flutter::EncodableValue>& call) {
  return std::get_if<flutter::EncodableMap>(call.arguments());
}

const flutter::EncodableValue* FindArgument(
    const flutter::EncodableMap& arguments, const char* key) {
  const auto iterator = arguments.find(flutter::EncodableValue(key));
  return iterator == arguments.end() ? nullptr : &iterator->second;
}

std::optional<std::string> ReadStringArgument(
    const flutter::EncodableMap& arguments, const char* key) {
  const auto* value = FindArgument(arguments, key);
  if (value == nullptr) {
    return std::nullopt;
  }
  const auto* text = std::get_if<std::string>(value);
  return text == nullptr ? std::nullopt
                         : std::optional<std::string>(*text);
}

std::optional<bool> ReadBoolArgument(const flutter::EncodableMap& arguments,
                                     const char* key) {
  const auto* value = FindArgument(arguments, key);
  if (value == nullptr) {
    return std::nullopt;
  }
  const auto* flag = std::get_if<bool>(value);
  return flag == nullptr ? std::nullopt : std::optional<bool>(*flag);
}

std::optional<int> ReadIntArgument(const flutter::EncodableMap& arguments,
                                   const char* key) {
  const auto* value = FindArgument(arguments, key);
  if (value == nullptr) {
    return std::nullopt;
  }
  if (const auto* number = std::get_if<int32_t>(value)) {
    return *number;
  }
  if (const auto* number = std::get_if<int64_t>(value)) {
    if (*number < std::numeric_limits<int>::min() ||
        *number > std::numeric_limits<int>::max()) {
      return std::nullopt;
    }
    return static_cast<int>(*number);
  }
  return std::nullopt;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  RegisterTextToSpeechChannel();
  RegisterWindowLifecycleChannel();
  RegisterScreenLookupChannel();
  screen_lookup_popup_ = std::make_unique<ScreenLookupPopup>(
      GetHandle(), [this](const std::string& action) {
        NotifyScreenLookupAction(action);
      });
  taskbar_created_message_ = RegisterWindowMessageW(L"TaskbarCreated");
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (screen_lookup_hotkey_registered_) {
    UnregisterHotKey(GetHandle(), screen_lookup_hotkey_id_);
    screen_lookup_hotkey_registered_ = false;
  }
  screen_lookup_popup_.reset();
  RemoveTrayIcon();
  screen_lookup_channel_.reset();
  window_lifecycle_channel_.reset();
  text_to_speech_channel_.reset();
  if (speech_voice_ != nullptr) {
    speech_voice_->Speak(nullptr, SPF_ASYNC | SPF_PURGEBEFORESPEAK, nullptr);
    speech_voice_->Release();
    speech_voice_ = nullptr;
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::RegisterScreenLookupChannel() {
  screen_lookup_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kScreenLookupChannel,
          &flutter::StandardMethodCodec::GetInstance());
  screen_lookup_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<
                 flutter::MethodResult<flutter::EncodableValue>> result) {
        const auto* arguments = ReadArguments(call);
        if (arguments == nullptr) {
          result->Error("invalid_arguments", "Missing screen lookup settings.");
          return;
        }
        if (call.method_name() == "setShortcutRecording") {
          const auto recording = ReadBoolArgument(*arguments, "recording");
          if (!recording.has_value()) {
            result->Error("invalid_arguments", "Missing recording state.");
            return;
          }
          std::string error;
          if (!SetShortcutRecording(*recording, &error)) {
            result->Error(error, "Unable to resume the lookup shortcut.");
            return;
          }
          result->Success(flutter::EncodableValue());
          return;
        }
        if (call.method_name() == "configure") {
          const auto enabled = ReadBoolArgument(*arguments, "enabled");
          const auto shortcut = ReadStringArgument(*arguments, "shortcut");
          if (!enabled.has_value() || !shortcut.has_value()) {
            result->Error("invalid_arguments", "Invalid screen lookup settings.");
            return;
          }
          std::string error;
          if (!ConfigureScreenLookup(*enabled, *shortcut, &error)) {
            result->Error(error, "The global shortcut is already in use.");
            return;
          }
          result->Success(flutter::EncodableValue());
          return;
        }
        if (call.method_name() == "hide") {
          if (screen_lookup_popup_ != nullptr) {
            screen_lookup_popup_->Hide();
          }
          result->Success(flutter::EncodableValue());
          return;
        }
        if (call.method_name() == "loadAiApiKey") {
          const auto secret = ReadAiApiKeyCredential();
          result->Success(flutter::EncodableValue(
              secret.has_value() ? Utf8FromUtf16(*secret) : std::string()));
          return;
        }
        if (call.method_name() == "saveAiApiKey") {
          const auto api_key = ReadStringArgument(*arguments, "apiKey");
          if (!api_key.has_value() || api_key->empty()) {
            result->Error("invalid_arguments", "Missing AI API key.");
            return;
          }
          std::wstring secret = Utf16FromUtf8(*api_key);
          const bool saved = WriteAiApiKeyCredential(secret);
          if (!secret.empty()) {
            SecureZeroMemory(secret.data(), secret.size() * sizeof(wchar_t));
          }
          if (!saved) {
            result->Error("credential_write_failed",
                          "Unable to save the AI API key securely.");
            return;
          }
          result->Success(flutter::EncodableValue());
          return;
        }
        if (call.method_name() == "deleteAiApiKey") {
          if (!DeleteAiApiKeyCredential()) {
            result->Error("credential_delete_failed",
                          "Unable to delete the AI API key.");
            return;
          }
          result->Success(flutter::EncodableValue());
          return;
        }
        if (call.method_name() == "updateAiResult") {
          const auto payload = ReadStringArgument(*arguments, "payload");
          const auto pending = ReadBoolArgument(*arguments, "pending");
          if (!payload.has_value() || payload->empty() ||
              !pending.has_value()) {
            result->Error("invalid_arguments", "Missing AI result payload.");
            return;
          }
          if (screen_lookup_popup_ != nullptr) {
            screen_lookup_popup_->UpdateAiResult(Utf16FromUtf8(*payload),
                                                 *pending);
          }
          result->Success(flutter::EncodableValue());
          return;
        }

        const auto x = ReadIntArgument(*arguments, "x");
        const auto y = ReadIntArgument(*arguments, "y");
        if (x.has_value() && y.has_value()) {
          current_screen_lookup_anchor_ = {*x, *y};
        }
        if (screen_lookup_popup_ == nullptr) {
          result->Error("popup_unavailable", "The lookup popup is unavailable.");
          return;
        }
        if (call.method_name() == "showLoading") {
          const auto query = ReadStringArgument(*arguments, "query");
          if (!query.has_value()) {
            result->Error("invalid_arguments", "Missing lookup query.");
            return;
          }
          current_screen_lookup_query_ = Utf16FromUtf8(*query);
          screen_lookup_popup_->ShowLoading(current_screen_lookup_query_,
                                            current_screen_lookup_anchor_);
          result->Success(flutter::EncodableValue());
          return;
        }
        if (call.method_name() == "showArticle") {
          const auto uri = ReadStringArgument(*arguments, "uri");
          if (!uri.has_value()) {
            result->Error("invalid_arguments", "Missing article URI.");
            return;
          }
          const auto query = ReadStringArgument(*arguments, "query");
          if (query.has_value() && !query->empty() && query->size() <= 512) {
            current_screen_lookup_query_ = Utf16FromUtf8(*query);
          }
          screen_lookup_popup_->ShowArticle(Utf16FromUtf8(*uri),
                                            current_screen_lookup_anchor_);
          result->Success(flutter::EncodableValue());
          return;
        }
        if (call.method_name() == "showMessage") {
          const auto title = ReadStringArgument(*arguments, "title");
          const auto message = ReadStringArgument(*arguments, "message");
          if (!title.has_value() || !message.has_value()) {
            result->Error("invalid_arguments", "Missing popup message.");
            return;
          }
          screen_lookup_popup_->ShowMessage(
              Utf16FromUtf8(*title), Utf16FromUtf8(*message),
              current_screen_lookup_anchor_);
          result->Success(flutter::EncodableValue());
          return;
        }
        result->NotImplemented();
      });
}

bool FlutterWindow::ConfigureScreenLookup(bool enabled,
                                          const std::string& shortcut,
                                          std::string* error) {
  if (!enabled) {
    if (screen_lookup_hotkey_registered_) {
      UnregisterHotKey(GetHandle(), screen_lookup_hotkey_id_);
      screen_lookup_hotkey_registered_ = false;
    }
    screen_lookup_enabled_ = false;
    if (screen_lookup_popup_ != nullptr) {
      screen_lookup_popup_->Hide();
    }
    if (!hide_to_tray_on_close_) {
      RemoveTrayIcon();
    }
    return true;
  }

  ScreenLookupHotkey hotkey{};
  if (!ParseScreenLookupHotkey(shortcut, &hotkey)) {
    if (error != nullptr) {
      *error = "invalid_shortcut";
    }
    return false;
  }
  const UINT modifiers = hotkey.modifiers | MOD_NOREPEAT;
  const UINT key = hotkey.key;
  const bool had_tray_icon = tray_icon_added_;
  if (!AddTrayIcon()) {
    if (error != nullptr) *error = "tray_unavailable";
    return false;
  }
  if (screen_lookup_hotkey_registered_ &&
      screen_lookup_hotkey_modifiers_ == modifiers &&
      screen_lookup_hotkey_key_ == key) return true;
  if (screen_lookup_shortcut_recording_) {
    screen_lookup_hotkey_modifiers_ = modifiers;
    screen_lookup_hotkey_key_ = key;
    screen_lookup_enabled_ = true;
    return true;
  }
  // Register the replacement first. A conflict must not disable the old key.
  const int candidate_id = screen_lookup_hotkey_id_ == 2 ? 3 : 2;
  if (!RegisterHotKey(GetHandle(), candidate_id, modifiers, key)) {
    if (!had_tray_icon && !hide_to_tray_on_close_) RemoveTrayIcon();
    if (error != nullptr) {
      *error = "hotkey_unavailable";
    }
    return false;
  }
  if (screen_lookup_hotkey_registered_) {
    UnregisterHotKey(GetHandle(), screen_lookup_hotkey_id_);
  }
  screen_lookup_hotkey_id_ = candidate_id;
  screen_lookup_hotkey_modifiers_ = modifiers;
  screen_lookup_hotkey_key_ = key;
  screen_lookup_hotkey_registered_ = true;
  screen_lookup_enabled_ = true;
  return true;
}

bool FlutterWindow::SetShortcutRecording(bool recording, std::string* error) {
  if (recording == screen_lookup_shortcut_recording_) return true;
  if (recording) {
    if (screen_lookup_hotkey_registered_) {
      if (!UnregisterHotKey(GetHandle(), screen_lookup_hotkey_id_)) {
        if (error != nullptr) *error = "hotkey_suspend_failed";
        return false;
      }
      screen_lookup_hotkey_registered_ = false;
    }
    if (screen_lookup_popup_ != nullptr) screen_lookup_popup_->Hide();
    screen_lookup_shortcut_recording_ = true;
    return true;
  }
  screen_lookup_shortcut_recording_ = false;
  if (!screen_lookup_enabled_) return true;
  if (!RegisterHotKey(GetHandle(), screen_lookup_hotkey_id_,
                      screen_lookup_hotkey_modifiers_, screen_lookup_hotkey_key_)) {
    screen_lookup_enabled_ = false;
    if (error != nullptr) *error = "hotkey_unavailable";
    return false;
  }
  screen_lookup_hotkey_registered_ = true;
  return true;
}

void FlutterWindow::HandleScreenLookupResult(ScreenLookupResult* raw_result) {
  std::unique_ptr<ScreenLookupResult> result(raw_result);
  if (result == nullptr || screen_lookup_channel_ == nullptr ||
      !screen_lookup_enabled_ || screen_lookup_shortcut_recording_) {
    return;
  }
  current_screen_lookup_anchor_ = result->anchor;
  flutter::EncodableMap arguments;
  arguments[flutter::EncodableValue("x")] =
      flutter::EncodableValue(static_cast<int32_t>(result->anchor.x));
  arguments[flutter::EncodableValue("y")] =
      flutter::EncodableValue(static_cast<int32_t>(result->anchor.y));
  if (!result->text.empty()) {
    current_screen_lookup_query_ = result->text;
    arguments[flutter::EncodableValue("text")] =
        flutter::EncodableValue(Utf8FromUtf16(result->text));
    arguments[flutter::EncodableValue("context")] =
        flutter::EncodableValue(Utf8FromUtf16(result->context));
    arguments[flutter::EncodableValue("usedClipboardFallback")] =
        flutter::EncodableValue(result->used_clipboard_fallback);
    screen_lookup_channel_->InvokeMethod(
        "lookupRequested",
        std::make_unique<flutter::EncodableValue>(arguments));
    return;
  }
  current_screen_lookup_query_.clear();
  arguments[flutter::EncodableValue("error")] =
      flutter::EncodableValue(result->error);
  screen_lookup_channel_->InvokeMethod(
      "lookupUnavailable",
      std::make_unique<flutter::EncodableValue>(arguments));
}

void FlutterWindow::NotifyScreenLookupAction(const std::string& action) {
  if (screen_lookup_channel_ == nullptr) {
    return;
  }
  if (action == "openMain") {
    RestoreWindowFromTray();
    flutter::EncodableMap arguments;
    arguments[flutter::EncodableValue("text")] =
        flutter::EncodableValue(Utf8FromUtf16(current_screen_lookup_query_));
    screen_lookup_channel_->InvokeMethod(
        "openInMain", std::make_unique<flutter::EncodableValue>(arguments));
  } else if (action == "closed") {
    screen_lookup_channel_->InvokeMethod("screenLookupClosed", nullptr);
  } else if (action == "toggleFavorite") {
    screen_lookup_channel_->InvokeMethod("toggleFavorite", nullptr);
  } else if (action == "analyzeAi") {
    screen_lookup_channel_->InvokeMethod("analyzeAi", nullptr);
  } else if (action == "viewRelatedHeadword") {
    screen_lookup_channel_->InvokeMethod("viewRelatedHeadword", nullptr);
  } else if (action == "viewAiLemma") {
    screen_lookup_channel_->InvokeMethod("viewAiLemma", nullptr);
  } else if (action.rfind("lookupForm:", 0) == 0) {
    const char* raw_index = action.c_str() + std::string("lookupForm:").size();
    char* end = nullptr;
    const long index = std::strtol(raw_index, &end, 10);
    if (end != raw_index && end != nullptr && *end == '\0' && index >= -1 && index <= 7) {
      flutter::EncodableMap arguments;
      arguments[flutter::EncodableValue("index")] = flutter::EncodableValue(static_cast<int32_t>(index));
      screen_lookup_channel_->InvokeMethod("selectLookupForm", std::make_unique<flutter::EncodableValue>(arguments));
    }
  } else if (action == "pin:on" || action == "pin:off") {
    flutter::EncodableMap arguments;
    arguments[flutter::EncodableValue("pinned")] =
        flutter::EncodableValue(action == "pin:on");
    screen_lookup_channel_->InvokeMethod(
        "pinChanged", std::make_unique<flutter::EncodableValue>(arguments));
  } else if (action.rfind("dictionary:", 0) == 0) {
    const char* raw_index = action.c_str() + std::string("dictionary:").size();
    char* end = nullptr;
    const long index = std::strtol(raw_index, &end, 10);
    if (end != raw_index && end != nullptr && *end == '\0' && index >= 0 &&
        index <= std::numeric_limits<int32_t>::max()) {
      flutter::EncodableMap arguments;
      arguments[flutter::EncodableValue("index")] =
          flutter::EncodableValue(static_cast<int32_t>(index));
      screen_lookup_channel_->InvokeMethod(
          "selectDictionary",
          std::make_unique<flutter::EncodableValue>(arguments));
    }
  } else if (action.rfind("scope:", 0) == 0) {
    const char* raw_code = action.c_str() + std::string("scope:").size();
    char* end = nullptr;
    const long code = std::strtol(raw_code, &end, 10);
    if (end != raw_code && end != nullptr && *end == '\0' && code >= -2 &&
        code <= std::numeric_limits<int32_t>::max()) {
      flutter::EncodableMap arguments;
      arguments[flutter::EncodableValue("scopeCode")] =
          flutter::EncodableValue(static_cast<int32_t>(code));
      screen_lookup_channel_->InvokeMethod(
          "selectDictionaryScope",
          std::make_unique<flutter::EncodableValue>(arguments));
    }
  } else if (action.rfind("playSound:", 0) == 0) {
    flutter::EncodableMap arguments;
    arguments[flutter::EncodableValue("value")] = flutter::EncodableValue(
        action.substr(std::string("playSound:").size()));
    screen_lookup_channel_->InvokeMethod(
        "playSound", std::make_unique<flutter::EncodableValue>(arguments));
  } else if (action.rfind("speak:", 0) == 0) {
    flutter::EncodableMap arguments;
    arguments[flutter::EncodableValue("value")] =
        flutter::EncodableValue(action.substr(std::string("speak:").size()));
    screen_lookup_channel_->InvokeMethod(
        "speak", std::make_unique<flutter::EncodableValue>(arguments));
  }
}

void FlutterWindow::RegisterWindowLifecycleChannel() {
  window_lifecycle_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kWindowLifecycleChannel,
          &flutter::StandardMethodCodec::GetInstance());
  window_lifecycle_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<
                 flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "setCloseBehavior") {
          result->NotImplemented();
          return;
        }
        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Error("invalid_arguments", "Missing close behavior settings.");
          return;
        }
        const auto behavior_iterator =
            arguments->find(flutter::EncodableValue("behavior"));
        const auto* behavior = behavior_iterator == arguments->end()
                                   ? nullptr
                                   : std::get_if<std::string>(
                                         &behavior_iterator->second);
        if (behavior == nullptr ||
            (*behavior != "exit" && *behavior != "hideToTray")) {
          result->Error("invalid_arguments", "Unknown close behavior.");
          return;
        }
        const auto notification_iterator = arguments->find(
            flutter::EncodableValue("showFirstHideNotification"));
        const auto* show_notification =
            notification_iterator == arguments->end()
                ? nullptr
                : std::get_if<bool>(&notification_iterator->second);
        show_first_hide_notification_ =
            show_notification == nullptr ? false : *show_notification;

        if (*behavior == "hideToTray") {
          if (!AddTrayIcon()) {
            hide_to_tray_on_close_ = false;
            result->Error("tray_unavailable",
                          "Windows could not create the system tray icon.");
            return;
          }
          hide_to_tray_on_close_ = true;
        } else {
          hide_to_tray_on_close_ = false;
          if (!screen_lookup_enabled_) {
            RemoveTrayIcon();
          }
        }
        result->Success(flutter::EncodableValue());
      });
}

bool FlutterWindow::AddTrayIcon() {
  if (tray_icon_added_) {
    return true;
  }
  const HWND window = GetHandle();
  if (window == nullptr) {
    return false;
  }
  tray_icon_data_ = {};
  tray_icon_data_.cbSize = sizeof(tray_icon_data_);
  tray_icon_data_.hWnd = window;
  tray_icon_data_.uID = kTrayIconId;
  tray_icon_data_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  tray_icon_data_.uCallbackMessage = kTrayCallbackMessage;
  tray_icon_data_.hIcon =
      LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(tray_icon_data_.szTip, _countof(tray_icon_data_.szTip), L"LumaLex");
  if (!Shell_NotifyIconW(NIM_ADD, &tray_icon_data_)) {
    return false;
  }
  tray_icon_added_ = true;
  NOTIFYICONDATAW version_data = tray_icon_data_;
  version_data.uVersion = NOTIFYICON_VERSION_4;
  Shell_NotifyIconW(NIM_SETVERSION, &version_data);
  return true;
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_icon_added_) {
    return;
  }
  Shell_NotifyIconW(NIM_DELETE, &tray_icon_data_);
  tray_icon_added_ = false;
}

bool FlutterWindow::HideWindowToTray() {
  if (!AddTrayIcon()) {
    hide_to_tray_on_close_ = false;
    return false;
  }
  if (speech_voice_ != nullptr) {
    speech_voice_->Speak(nullptr, SPF_ASYNC | SPF_PURGEBEFORESPEAK, nullptr);
  }
  ShowWindow(GetHandle(), SW_HIDE);
  NotifyWindowLifecycle("hiddenToTray");
  ShowFirstHideNotification();
  return true;
}

void FlutterWindow::RestoreWindowFromTray() {
  const HWND window = GetHandle();
  if (window == nullptr) {
    return;
  }
  ShowWindow(window, IsIconic(window) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(window);
  NotifyWindowLifecycle("restoredFromTray");
}

void FlutterWindow::ShowTrayMenu() {
  const HWND window = GetHandle();
  if (window == nullptr) {
    return;
  }
  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }
  AppendMenuW(menu, MF_STRING, kTrayOpenCommand, L"打开 LumaLex");
  SetMenuDefaultItem(menu, kTrayOpenCommand, FALSE);
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kTrayExitCommand, L"退出 LumaLex");
  POINT point{};
  GetCursorPos(&point);
  SetForegroundWindow(window);
  const UINT command = TrackPopupMenu(
      menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON | TPM_BOTTOMALIGN |
                TPM_LEFTALIGN,
      point.x, point.y, 0, window, nullptr);
  DestroyMenu(menu);
  PostMessage(window, WM_NULL, 0, 0);
  if (command == kTrayOpenCommand) {
    RestoreWindowFromTray();
  } else if (command == kTrayExitCommand) {
    ExitFromTray();
  }
}

void FlutterWindow::ShowFirstHideNotification() {
  if (!show_first_hide_notification_ || !tray_icon_added_) {
    return;
  }
  NOTIFYICONDATAW notification = tray_icon_data_;
  notification.uFlags = NIF_INFO;
  wcscpy_s(notification.szInfoTitle, _countof(notification.szInfoTitle),
           L"LumaLex 已隐藏到系统托盘");
  wcscpy_s(notification.szInfo, _countof(notification.szInfo),
           L"单击托盘图标可恢复窗口，右键图标可彻底退出。");
  notification.dwInfoFlags = NIIF_INFO | NIIF_NOSOUND;
  if (Shell_NotifyIconW(NIM_MODIFY, &notification)) {
    show_first_hide_notification_ = false;
    NotifyWindowLifecycle("trayNotificationShown");
  }
}

void FlutterWindow::NotifyWindowLifecycle(const std::string& event) {
  if (window_lifecycle_channel_ != nullptr) {
    window_lifecycle_channel_->InvokeMethod(event, nullptr);
  }
}

void FlutterWindow::ExitFromTray() {
  force_exit_ = true;
  TerminateApplication();
}

void FlutterWindow::TerminateApplication() {
  RemoveTrayIcon();
  if (speech_voice_ != nullptr) {
    speech_voice_->Speak(nullptr, SPF_ASYNC | SPF_PURGEBEFORESPEAK, nullptr);
  }
  // flutter_inappwebview_windows 0.6.0 can raise 0xe0464645 from dcomp.dll
  // during process teardown, after the window has already closed. Preferences
  // and learning records are persisted eagerly, so bypass the affected DLL
  // destructor path and let Windows reclaim process-owned graphics resources.
  if (!TerminateProcess(GetCurrentProcess(), 0)) {
    const HWND window = GetHandle();
    if (window != nullptr) {
      DestroyWindow(window);
    }
  }
}

void FlutterWindow::RegisterTextToSpeechChannel() {
  text_to_speech_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kTextToSpeechChannel,
          &flutter::StandardMethodCodec::GetInstance());
  text_to_speech_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<
                 flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "stop") {
          if (speech_voice_ != nullptr) {
            speech_voice_->Speak(nullptr,
                                 SPF_ASYNC | SPF_PURGEBEFORESPEAK, nullptr);
          }
          result->Success(flutter::EncodableValue());
          return;
        }
        if (call.method_name() != "speak") {
          result->NotImplemented();
          return;
        }

        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Error("invalid_arguments", "Missing speech arguments.");
          return;
        }
        const auto text_iterator =
            arguments->find(flutter::EncodableValue("text"));
        if (text_iterator == arguments->end()) {
          result->Error("invalid_arguments", "Missing speech text.");
          return;
        }
        const auto* utf8_text =
            std::get_if<std::string>(&text_iterator->second);
        if (utf8_text == nullptr || utf8_text->empty() ||
            utf8_text->size() > 2000) {
          result->Error("invalid_arguments", "Invalid speech text.");
          return;
        }
        const std::wstring text = Utf16FromUtf8(*utf8_text);
        if (text.empty()) {
          result->Error("invalid_arguments", "Speech text is not UTF-8.");
          return;
        }

        if (speech_voice_ == nullptr) {
          const HRESULT create_result = ::CoCreateInstance(
              CLSID_SpVoice, nullptr, CLSCTX_INPROC_SERVER, IID_ISpVoice,
              reinterpret_cast<void**>(&speech_voice_));
          if (FAILED(create_result) || speech_voice_ == nullptr) {
            speech_voice_ = nullptr;
            result->Error("tts_unavailable",
                          "Windows Speech could not be started.");
            return;
          }
        }

        const HRESULT speak_result = speech_voice_->Speak(
            text.c_str(),
            SPF_ASYNC | SPF_PURGEBEFORESPEAK | SPF_IS_NOT_XML, nullptr);
        if (FAILED(speak_result)) {
          result->Error("tts_failed", "Windows Speech could not speak text.");
          return;
        }
        result->Success(flutter::EncodableValue(true));
      });
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == taskbar_created_message_ && taskbar_created_message_ != 0) {
    tray_icon_added_ = false;
    if ((hide_to_tray_on_close_ || screen_lookup_enabled_) &&
        !AddTrayIcon() && !IsWindowVisible(hwnd)) {
      RestoreWindowFromTray();
    }
    return 0;
  }
  if (message == kScreenLookupReadyMessage) {
    HandleScreenLookupResult(reinterpret_cast<ScreenLookupResult*>(lparam));
    return 0;
  }
  if (message == WM_HOTKEY && wparam == static_cast<WPARAM>(screen_lookup_hotkey_id_)) {
    if (screen_lookup_enabled_ && screen_lookup_hotkey_registered_ &&
        !screen_lookup_shortcut_recording_) {
      screen_lookup_service_.RequestSelection(hwnd, kScreenLookupReadyMessage);
    }
    return 0;
  }
  if (message == kTrayCallbackMessage) {
    const UINT tray_event = LOWORD(lparam);
    if (tray_event == WM_LBUTTONUP || tray_event == WM_LBUTTONDBLCLK ||
        tray_event == NIN_SELECT || tray_event == NIN_KEYSELECT ||
        tray_event == NIN_BALLOONUSERCLICK) {
      RestoreWindowFromTray();
    } else if (tray_event == WM_RBUTTONUP || tray_event == WM_CONTEXTMENU) {
      ShowTrayMenu();
    }
    return 0;
  }
  if (message == WM_QUERYENDSESSION) {
    force_exit_ = true;
  } else if (message == WM_ENDSESSION && wparam == FALSE) {
    force_exit_ = false;
  }
  if (message == WM_CLOSE && hide_to_tray_on_close_ && !force_exit_) {
    if (HideWindowToTray()) {
      return 0;
    }
  }
  if (message == WM_CLOSE) {
    TerminateApplication();
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
