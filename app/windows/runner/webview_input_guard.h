#ifndef RUNNER_WEBVIEW_INPUT_GUARD_H_
#define RUNNER_WEBVIEW_INPUT_GUARD_H_

#include <windows.h>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

struct WebViewProcessRecord {
  DWORD id;
  DWORD parent;
  bool is_webview;
};

// Only WebView2 children of this host are eligible, never another app's browser.
inline std::unordered_set<DWORD> OwnedWebViewProcesses(
    DWORD host, const std::vector<WebViewProcessRecord>& processes) {
  std::unordered_set<DWORD> owned;
  bool changed = true;
  while (changed) {
    changed = false;
    for (const auto& process : processes) {
      if (process.is_webview && process.id != host &&
          (process.parent == host || owned.count(process.parent) != 0)) {
        changed = owned.insert(process.id).second || changed;
      }
    }
  }
  return owned;
}

inline bool IsInvisibleWebViewInputSurface(bool owned, bool top_level,
    bool chromium_surface, LONG_PTR ex_style, bool readable,
    DWORD alpha_flags, BYTE alpha) {
  return owned && top_level && chromium_surface && readable &&
      (ex_style & WS_EX_LAYERED) != 0 && (ex_style & WS_EX_NOACTIVATE) != 0 &&
      (alpha_flags & LWA_ALPHA) != 0 && alpha == 0;
}

class WebViewInputGuard {
 public:
  void Refresh();
  void Restore();

 private:
  struct ProtectedWindow { DWORD process; };
  void RestoreWindow(HWND window, DWORD process);
  std::unordered_map<HWND, ProtectedWindow> protected_windows_;
};

#endif
