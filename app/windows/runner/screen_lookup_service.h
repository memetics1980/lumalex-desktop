#ifndef RUNNER_SCREEN_LOOKUP_SERVICE_H_
#define RUNNER_SCREEN_LOOKUP_SERVICE_H_

#include <windows.h>

#include <atomic>
#include <string>
#include <thread>

struct ScreenLookupResult {
  std::wstring text;
  std::wstring context;
  POINT anchor{};
  bool used_clipboard_fallback = false;
  std::string error;
};

class ScreenLookupService {
 public:
  ScreenLookupService();
  ~ScreenLookupService();

  ScreenLookupService(const ScreenLookupService&) = delete;
  ScreenLookupService& operator=(const ScreenLookupService&) = delete;

  bool RequestSelection(HWND owner, UINT completion_message);

 private:
  std::atomic_bool in_progress_ = false;
  std::thread worker_;
};

#endif  // RUNNER_SCREEN_LOOKUP_SERVICE_H_
