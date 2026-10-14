#include "webview_input_guard.h"

#include <tlhelp32.h>
#include <cwchar>

namespace {
std::unordered_set<DWORD> BrowserProcesses() {
  const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return {};
  std::vector<WebViewProcessRecord> records;
  PROCESSENTRY32W process{};
  process.dwSize = sizeof(process);
  if (Process32FirstW(snapshot, &process)) {
    do {
      records.push_back({process.th32ProcessID, process.th32ParentProcessID,
        _wcsicmp(process.szExeFile, L"msedgewebview2.exe") == 0});
    } while (Process32NextW(snapshot, &process));
  }
  CloseHandle(snapshot);
  return OwnedWebViewProcesses(GetCurrentProcessId(), records);
}

struct Enumeration {
  const std::unordered_set<DWORD>* browsers;
  std::vector<HWND>* windows;
};

BOOL CALLBACK CollectSurface(HWND window, LPARAM argument) {
  auto* enumeration = reinterpret_cast<Enumeration*>(argument);
  DWORD process = 0;
  GetWindowThreadProcessId(window, &process);
  if (enumeration->browsers->count(process) == 0) return TRUE;
  wchar_t window_class[64]{};
  GetClassNameW(window, window_class, 64);
  if (wcscmp(window_class, L"Chrome_WidgetWin_1") == 0 &&
      (GetWindowLongPtrW(window, GWL_STYLE) & WS_CHILD) == 0) {
    enumeration->windows->push_back(window);
  }
  return TRUE;
}

bool ChangeTransparentFlag(HWND window, bool transparent) {
  const LONG_PTR current = GetWindowLongPtrW(window, GWL_EXSTYLE);
  const LONG_PTR desired = transparent ? current | WS_EX_TRANSPARENT
                                      : current & ~static_cast<LONG_PTR>(WS_EX_TRANSPARENT);
  if (current == desired) return true;
  SetLastError(ERROR_SUCCESS);
  const LONG_PTR previous = SetWindowLongPtrW(window, GWL_EXSTYLE, desired);
  if (previous == 0 && GetLastError() != ERROR_SUCCESS) return false;
  // Do not move, resize, activate or reorder the browser window.
  SetWindowPos(window, nullptr, 0, 0, 0, 0,
      SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
  return true;
}
}  // namespace

void WebViewInputGuard::RestoreWindow(HWND window, DWORD process) {
  DWORD actual_process = 0;
  if (IsWindow(window)) GetWindowThreadProcessId(window, &actual_process);
  if (actual_process == process) ChangeTransparentFlag(window, false);
  protected_windows_.erase(window);
}

void WebViewInputGuard::Refresh() {
  // Remove dead/recycled handles without modifying their replacement windows.
  for (auto entry = protected_windows_.begin(); entry != protected_windows_.end();) {
    DWORD process = 0;
    if (IsWindow(entry->first)) GetWindowThreadProcessId(entry->first, &process);
    if (process != entry->second.process) entry = protected_windows_.erase(entry);
    else ++entry;
  }
  const auto browsers = BrowserProcesses();
  std::vector<HWND> windows;
  Enumeration enumeration{&browsers, &windows};
  EnumWindows(CollectSurface, reinterpret_cast<LPARAM>(&enumeration));
  for (const HWND window : windows) {
    DWORD key = 0, flags = 0, process = 0;
    BYTE alpha = 255;
    const LONG_PTR style = GetWindowLongPtrW(window, GWL_EXSTYLE);
    const bool readable = GetLayeredWindowAttributes(window, &key, &alpha, &flags) != FALSE;
    GetWindowThreadProcessId(window, &process);
    const auto protected_window = protected_windows_.find(window);
    if (IsInvisibleWebViewInputSurface(true, true, true, style, readable, flags, alpha)) {
      if ((style & WS_EX_TRANSPARENT) == 0 && ChangeTransparentFlag(window, true)) {
        protected_windows_[window] = {process};
      }
    } else if (protected_window != protected_windows_.end() &&
        ((style & WS_EX_LAYERED) == 0 || (readable &&
          ((flags & LWA_ALPHA) == 0 || alpha != 0)))) {
      // Restore input if this exact surface becomes genuinely visible. Keep
      // every other style bit, and never unset transparency we did not add.
      RestoreWindow(window, process);
    }
  }
}

void WebViewInputGuard::Restore() {
  while (!protected_windows_.empty()) {
    const auto entry = *protected_windows_.begin();
    RestoreWindow(entry.first, entry.second.process);
  }
}
