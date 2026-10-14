#include "../webview_input_guard.h"

#include <cassert>
#include <iostream>

int main() {
  // Out-of-order descendants are included; unrelated apps and executable
  // names, self references and disconnected cycles are excluded.
  const auto owned = OwnedWebViewProcesses(10, {
    {13, 12, true}, {12, 11, true}, {11, 10, true},
    {21, 20, true}, {22, 10, false}, {23, 22, true},
    {10, 10, true}, {31, 32, true}, {32, 31, true}
  });
  assert(owned.size() == 3);
  assert(owned.count(11) && owned.count(12) && owned.count(13));
  assert(OwnedWebViewProcesses(10, {}).empty());

  const LONG_PTR style = WS_EX_LAYERED | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW;
  assert(IsInvisibleWebViewInputSurface(true, true, true, style, true, LWA_ALPHA, 0));
  assert(IsInvisibleWebViewInputSurface(true, true, true,
      style | WS_EX_TRANSPARENT, true, LWA_ALPHA, 0));
  assert(!IsInvisibleWebViewInputSurface(false, true, true, style, true, LWA_ALPHA, 0));
  assert(!IsInvisibleWebViewInputSurface(true, false, true, style, true, LWA_ALPHA, 0));
  assert(!IsInvisibleWebViewInputSurface(true, true, false, style, true, LWA_ALPHA, 0));
  assert(!IsInvisibleWebViewInputSurface(true, true, true, style, false, LWA_ALPHA, 0));
  assert(!IsInvisibleWebViewInputSurface(true, true, true,
      style & ~static_cast<LONG_PTR>(WS_EX_LAYERED), true, LWA_ALPHA, 0));
  assert(!IsInvisibleWebViewInputSurface(true, true, true,
      style & ~static_cast<LONG_PTR>(WS_EX_NOACTIVATE), true, LWA_ALPHA, 0));
  assert(!IsInvisibleWebViewInputSurface(true, true, true, style, true, LWA_COLORKEY, 0));
  assert(!IsInvisibleWebViewInputSurface(true, true, true, style, true, LWA_ALPHA, 1));
  assert(!IsInvisibleWebViewInputSurface(true, true, true, style, true, LWA_ALPHA, 255));

  // Safe smoke test: this process owns no browser. Refresh must not change
  // any other running application's surfaces.
  WebViewInputGuard guard;
  guard.Refresh();
  guard.Restore();
  std::cout << "WebView input ownership and transparency policy tests passed.\n";
}
