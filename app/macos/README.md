# LumaLex macOS development preview

The macOS host shares `app/lib/`, the Rust dictionary engine and the Flutter/Rust
bridge with Windows. It targets macOS 12 or later. It is not a signed public
release and does not yet implement screen lookup, native lookup popups,
menu-bar persistence or contextual AI settings.

## Build and run

Install Flutter stable (validated with 3.47.4), Xcode and its command-line tools,
CocoaPods, and Rust stable. Use an Apple Silicon Mac for an arm64 build or an
Intel Mac for an x86_64 build; the other architecture needs separate validation.
From `app/`:

```sh
flutter pub get
flutter analyze
flutter test
flutter run -d macos
flutter build macos --release
```

The application is `build/macos/Build/Products/Release/LumaLex.app`. Rust is built
and linked through the existing `rust_builder/macos` CocoaPods integration.
Keep the whole repository present when building.

## File access and networking

This initial host is for direct distribution, with App Sandbox disabled in both
debug and release configurations. The file-picker plugin requires the
user-selected read/write entitlement for import and learning-data export. It reads MDX/MDD and companion assets from
the user's selected folder without copying them into the app. Persistent library
paths remain usable after restarting. iOS bookmark channels are not invoked by
this desktop host. A future sandboxed or Mac App Store edition must first add
persistent, folder-scoped security bookmarks covering MDX, MDD and loose assets.

The article renderer serves dictionary HTML and resources on a local loopback
HTTP server. Preserve this server in release builds as well as development.
User settings and indexes live in platform application-support directories.
macOS and Windows have separate local data; sharing a repository does not sync
user files, preferences or credentials.

## Validate before delivery

- Import a folder with MDX and its MDD files; restart and confirm access persists.
- Look up known words, switch dictionaries and groups, and check HTML, CSS,
  images, fonts, links, audio and system speech with representative dictionaries.
- Check history, favorites, reviews and learning-data export/restore.
- Resize the main window and return from settings without losing the article.
- Test a release build independently of `flutter run` on each supported CPU.
- Sign with Developer ID and notarize before public distribution. Keep signing
  credentials out of Git. Package and checksum the validated app separately.

Windows integration stays in `app/windows/`. Do not apply WebView2-specific
workarounds to WebKit without reproducing the underlying issue on macOS.
