#ifndef RUNNER_SCREEN_LOOKUP_POPUP_H_
#define RUNNER_SCREEN_LOOKUP_POPUP_H_

#include <windows.h>

#include <functional>
#include <string>

#include <wrl/client.h>

struct ICoreWebView2;
struct ICoreWebView2Controller;

class ScreenLookupPopup {
 public:
  using ActionHandler = std::function<void(const std::string& action)>;

  ScreenLookupPopup(HWND owner, ActionHandler action_handler);
  ~ScreenLookupPopup();

  ScreenLookupPopup(const ScreenLookupPopup&) = delete;
  ScreenLookupPopup& operator=(const ScreenLookupPopup&) = delete;

  void ShowLoading(const std::wstring& query, POINT anchor);
  void ShowArticle(const std::wstring& uri, POINT anchor);
  void UpdateAiResult(const std::wstring& encoded_payload, bool pending);
  void ShowMessage(const std::wstring& title,
                   const std::wstring& message,
                   POINT anchor);
  void Hide();
  bool is_visible() const;

 private:
  enum class PendingContentType { kNone, kHtml, kUri };

  static LRESULT CALLBACK WindowProc(HWND window,
                                     UINT message,
                                     WPARAM wparam,
                                     LPARAM lparam);
  static ATOM RegisterWindowClass();

  bool EnsureCreated();
  void InitializeWebView();
  void ResizeWebView();
  void PositionNear(POINT anchor);
  void MoveByDragOffset(int x, int y);
  void ApplyPendingContent();
  void ResetDismissTimer();
  void HandleWebMessage(const std::wstring& message);
  std::wstring BuildStatusHtml(const std::wstring& title,
                               const std::wstring& message,
                               bool loading) const;

  HWND owner_ = nullptr;
  HWND window_ = nullptr;
  ActionHandler action_handler_;
  Microsoft::WRL::ComPtr<ICoreWebView2Controller> controller_;
  Microsoft::WRL::ComPtr<ICoreWebView2> webview_;
  PendingContentType pending_type_ = PendingContentType::kNone;
  std::wstring pending_content_;
  POINT last_anchor_{};
  bool initialization_started_ = false;
  bool pinned_ = false;
  bool waiting_for_ai_ = false;
  bool pointer_inside_ = false;
  bool dragging_ = false;
  bool manually_positioned_ = false;
  POINT drag_origin_{};
  bool visible_ = false;
};

#endif  // RUNNER_SCREEN_LOOKUP_POPUP_H_
