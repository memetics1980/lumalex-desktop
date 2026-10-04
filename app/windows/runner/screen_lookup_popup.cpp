#include "screen_lookup_popup.h"

#include <WebView2.h>
#include <dwmapi.h>
#include <wrl/event.h>

#include <algorithm>
#include <cwchar>
#include <iterator>
#include <string>
#include <utility>

namespace {

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;

constexpr wchar_t kPopupWindowClass[] = L"LumaLex.ScreenLookupPopup";
constexpr UINT_PTR kDismissTimerId = 1;
constexpr UINT kDismissDelayMilliseconds = 5000;
constexpr int kPopupLogicalWidth = 560;
constexpr int kPopupLogicalHeight = 520;
constexpr int kPopupLogicalGap = 14;

int ScaleForDpi(int value, UINT dpi) {
  return MulDiv(value, static_cast<int>(dpi == 0 ? 96 : dpi), 96);
}

std::wstring EscapeHtml(const std::wstring& value) {
  std::wstring escaped;
  escaped.reserve(value.size());
  for (const wchar_t character : value) {
    switch (character) {
      case L'&':
        escaped.append(L"&amp;");
        break;
      case L'<':
        escaped.append(L"&lt;");
        break;
      case L'>':
        escaped.append(L"&gt;");
        break;
      case L'\"':
        escaped.append(L"&quot;");
        break;
      case L'\'':
        escaped.append(L"&#39;");
        break;
      default:
        escaped.push_back(character);
        break;
    }
  }
  return escaped;
}

std::string AsciiFromWide(const std::wstring& value) {
  std::string output;
  output.reserve(value.size());
  for (const wchar_t character : value) {
    if (character > 0x7f) {
      return std::string();
    }
    output.push_back(static_cast<char>(character));
  }
  return output;
}

bool IsBase64Payload(const std::wstring& value) {
  if (value.empty() || value.size() > 256 * 1024) {
    return false;
  }
  return std::all_of(value.begin(), value.end(), [](wchar_t character) {
    return (character >= L'A' && character <= L'Z') ||
           (character >= L'a' && character <= L'z') ||
           (character >= L'0' && character <= L'9') || character == L'+' ||
           character == L'/' || character == L'=';
  });
}

bool ParseDragOffset(const std::wstring& message, int* x, int* y) {
  constexpr wchar_t kPrefix[] = L"drag:move:";
  if (message.rfind(kPrefix, 0) != 0) {
    return false;
  }
  const wchar_t* cursor = message.c_str() + std::size(kPrefix) - 1;
  wchar_t* end = nullptr;
  const long parsed_x = std::wcstol(cursor, &end, 10);
  if (end == cursor || *end != L':') {
    return false;
  }
  cursor = end + 1;
  const long parsed_y = std::wcstol(cursor, &end, 10);
  if (end == cursor || *end != L'\0' || parsed_x < -32768 ||
      parsed_x > 32768 || parsed_y < -32768 || parsed_y > 32768) {
    return false;
  }
  *x = static_cast<int>(parsed_x);
  *y = static_cast<int>(parsed_y);
  return true;
}

}  // namespace

ScreenLookupPopup::ScreenLookupPopup(HWND owner, ActionHandler action_handler)
    : owner_(owner), action_handler_(std::move(action_handler)) {}

ScreenLookupPopup::~ScreenLookupPopup() {
  if (window_ != nullptr) {
    KillTimer(window_, kDismissTimerId);
  }
  if (controller_ != nullptr) {
    controller_->Close();
  }
  webview_.Reset();
  controller_.Reset();
  if (window_ != nullptr) {
    DestroyWindow(window_);
    window_ = nullptr;
  }
}

ATOM ScreenLookupPopup::RegisterWindowClass() {
  static ATOM window_class = 0;
  if (window_class != 0) {
    return window_class;
  }
  WNDCLASSEXW definition{};
  definition.cbSize = sizeof(definition);
  definition.lpfnWndProc = ScreenLookupPopup::WindowProc;
  definition.hInstance = GetModuleHandle(nullptr);
  definition.hCursor = LoadCursor(nullptr, IDC_ARROW);
  definition.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
  definition.lpszClassName = kPopupWindowClass;
  window_class = RegisterClassExW(&definition);
  return window_class;
}

bool ScreenLookupPopup::EnsureCreated() {
  if (window_ != nullptr) {
    return true;
  }
  if (RegisterWindowClass() == 0) {
    return false;
  }
  window_ = CreateWindowExW(
      WS_EX_TOOLWINDOW | WS_EX_TOPMOST, kPopupWindowClass, L"LumaLex 屏幕取词",
      WS_POPUP, CW_USEDEFAULT, CW_USEDEFAULT, kPopupLogicalWidth,
      kPopupLogicalHeight, owner_, nullptr, GetModuleHandle(nullptr), this);
  if (window_ == nullptr) {
    return false;
  }
  const DWORD corner_preference = 2;  // DWMWCP_ROUND on Windows 11.
  DwmSetWindowAttribute(window_, 33, &corner_preference,
                        sizeof(corner_preference));
  InitializeWebView();
  return true;
}

void ScreenLookupPopup::InitializeWebView() {
  if (initialization_started_ || window_ == nullptr) {
    return;
  }
  initialization_started_ = true;
  wchar_t temporary_path[MAX_PATH] = {};
  std::wstring user_data_folder;
  const DWORD temporary_length =
      GetTempPathW(static_cast<DWORD>(std::size(temporary_path)),
                   temporary_path);
  if (temporary_length > 0 && temporary_length < std::size(temporary_path)) {
    user_data_folder.assign(temporary_path, temporary_length);
    user_data_folder.append(L"LumaLexScreenLookupWebView2");
    CreateDirectoryW(user_data_folder.c_str(), nullptr);
  }

  const HRESULT environment_result = CreateCoreWebView2EnvironmentWithOptions(
      nullptr, user_data_folder.empty() ? nullptr : user_data_folder.c_str(),
      nullptr,
      Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
          [this](HRESULT result,
                 ICoreWebView2Environment* environment) -> HRESULT {
            if (FAILED(result) || environment == nullptr || window_ == nullptr) {
              initialization_started_ = false;
              return S_OK;
            }
            environment->CreateCoreWebView2Controller(
                window_,
                Callback<
                    ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                    [this](HRESULT controller_result,
                           ICoreWebView2Controller* controller) -> HRESULT {
                      if (FAILED(controller_result) || controller == nullptr ||
                          window_ == nullptr) {
                        initialization_started_ = false;
                        return S_OK;
                      }
                      controller_ = controller;
                      controller_->get_CoreWebView2(&webview_);
                      ComPtr<ICoreWebView2Settings> settings;
                      if (webview_ != nullptr &&
                          SUCCEEDED(webview_->get_Settings(&settings)) &&
                          settings != nullptr) {
                        settings->put_AreDefaultContextMenusEnabled(FALSE);
                        settings->put_AreDevToolsEnabled(FALSE);
                        settings->put_IsStatusBarEnabled(FALSE);
                      }
                      if (webview_ != nullptr) {
                        EventRegistrationToken message_token{};
                        webview_->add_WebMessageReceived(
                            Callback<
                                ICoreWebView2WebMessageReceivedEventHandler>(
                                [this](ICoreWebView2*,
                                       ICoreWebView2WebMessageReceivedEventArgs*
                                           args) -> HRESULT {
                                  LPWSTR raw_message = nullptr;
                                  if (args != nullptr &&
                                      SUCCEEDED(args->TryGetWebMessageAsString(
                                          &raw_message)) &&
                                      raw_message != nullptr) {
                                    HandleWebMessage(raw_message);
                                  }
                                  CoTaskMemFree(raw_message);
                                  return S_OK;
                                })
                                .Get(),
                            &message_token);
                      }
                      ResizeWebView();
                      controller_->put_IsVisible(visible_ ? TRUE : FALSE);
                      ApplyPendingContent();
                      return S_OK;
                    })
                    .Get());
            return S_OK;
          })
          .Get());
  if (FAILED(environment_result)) {
    initialization_started_ = false;
  }
}

void ScreenLookupPopup::ResizeWebView() {
  if (controller_ == nullptr || window_ == nullptr) {
    return;
  }
  RECT bounds{};
  GetClientRect(window_, &bounds);
  controller_->put_Bounds(bounds);
}

void ScreenLookupPopup::PositionNear(POINT anchor) {
  if (window_ == nullptr) {
    return;
  }
  last_anchor_ = anchor;
  HMONITOR monitor = MonitorFromPoint(anchor, MONITOR_DEFAULTTONEAREST);
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  GetMonitorInfoW(monitor, &monitor_info);
  const UINT dpi = GetDpiForWindow(window_);
  const int width = ScaleForDpi(kPopupLogicalWidth, dpi);
  const int height = ScaleForDpi(kPopupLogicalHeight, dpi);
  const int gap = ScaleForDpi(kPopupLogicalGap, dpi);

  int left = anchor.x + gap;
  int top = anchor.y + gap;
  if (left + width > monitor_info.rcWork.right) {
    left = anchor.x - width - gap;
  }
  if (top + height > monitor_info.rcWork.bottom) {
    top = anchor.y - height - gap;
  }
  const int work_left = static_cast<int>(monitor_info.rcWork.left);
  const int work_top = static_cast<int>(monitor_info.rcWork.top);
  const int work_right = static_cast<int>(monitor_info.rcWork.right);
  const int work_bottom = static_cast<int>(monitor_info.rcWork.bottom);
  left = std::clamp(left, work_left, std::max(work_left, work_right - width));
  top = std::clamp(top, work_top, std::max(work_top, work_bottom - height));
  SetWindowPos(window_, HWND_TOPMOST, left, top, width, height,
               SWP_NOACTIVATE | SWP_SHOWWINDOW);
  POINT cursor{};
  RECT window_bounds{};
  pointer_inside_ = GetCursorPos(&cursor) &&
                    GetWindowRect(window_, &window_bounds) &&
                    PtInRect(&window_bounds, cursor);
}

void ScreenLookupPopup::MoveByDragOffset(int x, int y) {
  if (!dragging_ || window_ == nullptr || !visible_) {
    return;
  }
  RECT bounds{};
  if (!GetWindowRect(window_, &bounds)) {
    return;
  }
  const int width = bounds.right - bounds.left;
  const int height = bounds.bottom - bounds.top;
  int left = drag_origin_.x + x;
  int top = drag_origin_.y + y;
  const POINT center{left + width / 2, top + height / 2};
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  const HMONITOR monitor = MonitorFromPoint(center, MONITOR_DEFAULTTONEAREST);
  if (!GetMonitorInfoW(monitor, &monitor_info)) {
    return;
  }
  const RECT& work = monitor_info.rcWork;
  left = std::clamp(left, static_cast<int>(work.left),
                    std::max(static_cast<int>(work.left),
                             static_cast<int>(work.right) - width));
  top = std::clamp(top, static_cast<int>(work.top),
                   std::max(static_cast<int>(work.top),
                            static_cast<int>(work.bottom) - height));
  SetWindowPos(window_, HWND_TOPMOST, left, top, 0, 0,
               SWP_NOACTIVATE | SWP_NOSIZE);
  manually_positioned_ = true;
}

void ScreenLookupPopup::ShowLoading(const std::wstring& query, POINT anchor) {
  if (!EnsureCreated()) {
    return;
  }
  pinned_ = false;
  waiting_for_ai_ = false;
  dragging_ = false;
  manually_positioned_ = false;
  pending_type_ = PendingContentType::kHtml;
  pending_content_ = BuildStatusHtml(
      L"正在查询“" + query + L"”", L"正在读取本地词典…", true);
  PositionNear(anchor);
  visible_ = true;
  ShowWindow(window_, SW_SHOWNOACTIVATE);
  if (controller_ != nullptr) {
    controller_->put_IsVisible(TRUE);
  }
  ApplyPendingContent();
  ResetDismissTimer();
}

void ScreenLookupPopup::ShowArticle(const std::wstring& uri, POINT anchor) {
  if (!EnsureCreated()) {
    return;
  }
  pending_type_ = PendingContentType::kUri;
  pending_content_ = uri;
  if (!manually_positioned_) {
    PositionNear(anchor);
  }
  visible_ = true;
  ShowWindow(window_, SW_SHOWNOACTIVATE);
  if (controller_ != nullptr) {
    controller_->put_IsVisible(TRUE);
  }
  ApplyPendingContent();
  ResetDismissTimer();
}

void ScreenLookupPopup::UpdateAiResult(const std::wstring& encoded_payload,
                                       bool pending) {
  if (webview_ == nullptr || !IsBase64Payload(encoded_payload)) {
    return;
  }
  const std::wstring script =
      L"window.lumalexApplyAiPayload && window.lumalexApplyAiPayload('" +
      encoded_payload + L"');";
  webview_->ExecuteScript(script.c_str(), nullptr);
  waiting_for_ai_ = pending;
  ResetDismissTimer();
}

void ScreenLookupPopup::ShowMessage(const std::wstring& title,
                                    const std::wstring& message,
                                    POINT anchor) {
  if (!EnsureCreated()) {
    return;
  }
  pinned_ = false;
  waiting_for_ai_ = false;
  dragging_ = false;
  manually_positioned_ = false;
  pending_type_ = PendingContentType::kHtml;
  pending_content_ = BuildStatusHtml(title, message, false);
  PositionNear(anchor);
  visible_ = true;
  ShowWindow(window_, SW_SHOWNOACTIVATE);
  if (controller_ != nullptr) {
    controller_->put_IsVisible(TRUE);
  }
  ApplyPendingContent();
  ResetDismissTimer();
}

void ScreenLookupPopup::ApplyPendingContent() {
  if (webview_ == nullptr || pending_content_.empty()) {
    return;
  }
  if (pending_type_ == PendingContentType::kUri) {
    webview_->Navigate(pending_content_.c_str());
  } else if (pending_type_ == PendingContentType::kHtml) {
    webview_->NavigateToString(pending_content_.c_str());
  }
}

void ScreenLookupPopup::ResetDismissTimer() {
  if (window_ == nullptr) {
    return;
  }
  KillTimer(window_, kDismissTimerId);
  if (!pinned_ && !waiting_for_ai_ && !pointer_inside_ && !dragging_) {
    SetTimer(window_, kDismissTimerId, kDismissDelayMilliseconds, nullptr);
  }
}

void ScreenLookupPopup::HandleWebMessage(const std::wstring& message) {
  if (message == L"close") {
    Hide();
  } else if (message == L"openMain") {
    Hide();
    if (action_handler_) {
      action_handler_("openMain");
    }
  } else if (message == L"pin") {
    pinned_ = !pinned_;
    ResetDismissTimer();
    if (action_handler_) {
      action_handler_(pinned_ ? "pin:on" : "pin:off");
    }
  } else if (message == L"interact") {
    ResetDismissTimer();
  } else if (message == L"pointer:inside") {
    pointer_inside_ = true;
    ResetDismissTimer();
  } else if (message == L"pointer:outside") {
    pointer_inside_ = false;
    ResetDismissTimer();
  } else if (message == L"drag:start") {
    RECT bounds{};
    if (visible_ && window_ != nullptr && GetWindowRect(window_, &bounds)) {
      drag_origin_ = POINT{bounds.left, bounds.top};
      dragging_ = true;
      pointer_inside_ = true;
      ResetDismissTimer();
    }
  } else if (message.rfind(L"drag:move:", 0) == 0) {
    int x = 0;
    int y = 0;
    if (ParseDragOffset(message, &x, &y)) {
      MoveByDragOffset(x, y);
    }
  } else if (message == L"drag:end:mouse" ||
             message == L"drag:end:touch") {
    dragging_ = false;
    if (message == L"drag:end:mouse" && window_ != nullptr) {
      POINT cursor{};
      RECT bounds{};
      pointer_inside_ = GetCursorPos(&cursor) &&
                        GetWindowRect(window_, &bounds) &&
                        PtInRect(&bounds, cursor);
    } else {
      pointer_inside_ = false;
    }
    ResetDismissTimer();
  } else if (message == L"analyzeAi") {
    waiting_for_ai_ = true;
    ResetDismissTimer();
    if (action_handler_) {
      action_handler_("analyzeAi");
    }
  } else if (message == L"toggleFavorite" ||
             message.rfind(L"dictionary:", 0) == 0 ||
             message.rfind(L"scope:", 0) == 0 ||
             message.rfind(L"playSound:", 0) == 0 ||
             message.rfind(L"speak:", 0) == 0) {
    if (action_handler_) {
      // Document actions are deliberately ASCII: dynamic values are URI
      // encoded by JavaScript before crossing the native boundary.
      const std::string action = AsciiFromWide(message);
      if (!action.empty()) {
        action_handler_(action);
      }
    }
  }
}

void ScreenLookupPopup::Hide() {
  if (!visible_) {
    return;
  }
  visible_ = false;
  waiting_for_ai_ = false;
  pointer_inside_ = false;
  dragging_ = false;
  manually_positioned_ = false;
  if (window_ != nullptr) {
    KillTimer(window_, kDismissTimerId);
    ShowWindow(window_, SW_HIDE);
  }
  if (controller_ != nullptr) {
    controller_->put_IsVisible(FALSE);
  }
  if (action_handler_) {
    action_handler_("closed");
  }
}

bool ScreenLookupPopup::is_visible() const {
  return visible_;
}

std::wstring ScreenLookupPopup::BuildStatusHtml(
    const std::wstring& title,
    const std::wstring& message,
    bool loading) const {
  const std::wstring spinner = loading
                                   ? L"<div class=\"spinner\"></div>"
                                   : L"<div class=\"mark\">Aa</div>";
  return L"<!doctype html><html><head><meta charset=\"utf-8\">"
         L"<meta name=\"viewport\" content=\"width=device-width\">"
         L"<style>*{box-sizing:border-box}html,body{margin:0;height:100%;"
         L"font-family:'Segoe UI','Microsoft YaHei UI',sans-serif;"
         L"background:#f8fafa;color:#172323}body{display:flex;align-items:center;"
         L"justify-content:center;padding:28px}.card{text-align:center;max-width:"
         L"420px}.spinner{width:38px;height:38px;margin:0 auto 20px;border:4px solid"
         L"#d5e6e7;border-top-color:#087e87;border-radius:50%;animation:s 0.8s linear"
         L" infinite}.mark{width:48px;height:48px;margin:0 auto 18px;border-radius:14px;"
         L"display:grid;place-items:center;background:#d9f3f4;color:#087e87;"
         L"font-weight:800;font-size:18px}@keyframes s{to{transform:rotate(360deg)}}"
         L"h1{font-size:21px;margin:0 0 9px}p{font-size:15px;line-height:1.55;"
         L"color:#506060;margin:0 0 22px}.actions{display:flex;gap:10px;"
         L"justify-content:center}button{min-height:44px;border-radius:12px;"
         L"border:1px solid #a7bcbc;background:white;padding:0 18px;font-size:15px;"
         L"cursor:pointer;color:#173333}button.primary{background:#087e87;"
         L"color:white;border-color:#087e87}</style></head><body>"
         L"<div class=\"card\">" + spinner + L"<h1>" + EscapeHtml(title) +
         L"</h1><p>" + EscapeHtml(message) +
         L"</p><div class=\"actions\"><button onclick=\"chrome.webview."
         L"postMessage('close')\">关闭</button><button class=\"primary\" "
         L"onclick=\"chrome.webview.postMessage('openMain')\">打开主窗口"
         L"</button></div></div><script>"
         L"document.documentElement.addEventListener('pointerenter',function(){"
         L"chrome.webview.postMessage('pointer:inside');});"
         L"document.documentElement.addEventListener('pointerleave',function(){"
         L"chrome.webview.postMessage('pointer:outside');});"
         L"</script></body></html>";
}

LRESULT CALLBACK ScreenLookupPopup::WindowProc(HWND window,
                                                UINT message,
                                                WPARAM wparam,
                                                LPARAM lparam) {
  ScreenLookupPopup* popup = reinterpret_cast<ScreenLookupPopup*>(
      GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    const auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    popup = static_cast<ScreenLookupPopup*>(create->lpCreateParams);
    SetWindowLongPtrW(window, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(popup));
  }
  if (popup == nullptr) {
    return DefWindowProcW(window, message, wparam, lparam);
  }
  switch (message) {
    case WM_SIZE:
      popup->ResizeWebView();
      return 0;
    case WM_TIMER:
      if (wparam == kDismissTimerId && !popup->pinned_ &&
          !popup->waiting_for_ai_ && !popup->pointer_inside_ &&
          !popup->dragging_) {
        popup->Hide();
        return 0;
      }
      break;
    case WM_KEYDOWN:
      if (wparam == VK_ESCAPE) {
        popup->Hide();
        return 0;
      }
      break;
    case WM_CLOSE:
      popup->Hide();
      return 0;
    case WM_DESTROY:
      popup->window_ = nullptr;
      return 0;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}
