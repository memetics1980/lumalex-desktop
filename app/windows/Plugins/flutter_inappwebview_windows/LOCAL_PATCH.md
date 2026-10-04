# Local Windows patch

This package is vendored from `flutter_inappwebview_windows` 0.6.0 so the
Windows release build is reproducible without modifying the shared Pub cache.

The native WebView2 setup disables its status bar with
`ICoreWebView2Settings::put_IsStatusBarEnabled(FALSE)`. This removes the link
address overlay that WebView2 otherwise displays at the bottom of dictionary
entries when users hover or click `entry://` and `sound://` links. Navigation,
audio playback, and the app's own URL interception are unchanged.

When the application disables Chromium's context menu, selected-text right
clicks are forwarded through the existing WebView channel to Flutter. Flutter
owns the visible touch-friendly Copy/Lookup popup, so the first command does
not depend on document focus or a JavaScript button inside publisher markup.

The plugin teardown order also releases headless, browser, and embedded
WebViews before their shared WebView2 environment. Upstream 0.6.0 released the
environment first, which can leave DirectComposition objects referring to a
destroyed environment and produce a `dcomp.dll` `0xe0464645` crash record when
the application exits.
