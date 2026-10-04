# LumaLex iOS WebView patch

This directory vendors `flutter_inappwebview_ios` 1.1.2 so the iOS reader can
reliably suppress WebKit's native selection menu.

iOS 18.2 and later may append **Copy Link with Highlight** even when
`canPerformAction(_:withSender:)` returns `false`. LumaLex draws its own
Flutter-based Copy/Lookup toolbar and sets `disableContextMenu` for iOS, so the
local patch returns from `InAppWebView.buildMenu(with:)` without calling
`super` when that setting is enabled.

When upgrading the upstream plugin, re-apply and test this conditional before
removing the dependency override in the app's `pubspec.yaml`.
