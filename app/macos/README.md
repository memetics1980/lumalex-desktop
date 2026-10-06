# LumaLex macOS development preview

The macOS host shares `app/lib/`, the Rust dictionary engine and the Flutter/Rust
bridge with Windows. It targets macOS 12 or later. It is not a signed public
release. It uses the same desktop settings, navigation, aggregate reader and
popup HTML as Windows, with separate native implementations.

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

## Desktop integration

- Main-window close behavior supports direct exit or hiding to the menu bar.
  Enabling screen lookup selects background operation. The menu bar can restore
  the main window, open settings, query selected text or exit. Dock reopening
  restores a hidden window; Command-comma opens settings.
- Lookup shortcuts are Command-Option-L, Command-Shift-L and Option-Q. Existing
  storage identifiers are kept compatible with the Windows settings contract.
  A shortcut conflict rolls back the setting instead of silently enabling it.
- Selection capture requires Accessibility permission. Use the settings link to
  grant it in System Settings; LumaLex does not grant itself permission. Native
  text ranges and WebKit/Chromium text markers supply up to 500 characters of
  context. Browser accessibility support and document-reader support vary.
- If no selection text is exposed, compatibility mode sends Command-C to the
  still-active source app and accepts only a new clipboard result. It changes
  the clipboard and has no contextual AI. Secure input/password fields are
  excluded. No screen recording, OCR or input-monitoring permission is required.
- The native non-activating WebKit popup shares dictionary/group switching,
  favorite controls, pronunciation, dragging, pinning and AI state with Windows.
  It closes five seconds after the pointer leaves, with pinning, dragging and
  pending AI pausing automatic closure. Main-window lookup remains available.
- API keys use macOS Keychain. AI requires the user's API endpoint/model/key and
  an explicit request. No external AI request is sent merely by selecting text.

Run the native tests after resolving Flutter dependencies/building the host:

```sh
cd macos
xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Debug \
  -destination 'platform=macOS' -only-testing:RunnerTests test
```

Native tests cover Unicode/bounded context, local popup origins, real WebKit
message delivery and an isolated Keychain credential. They never write or delete
the user's API key. Validate global shortcuts and capture manually in a browser,
a text editor and the document/PDF apps used for reading before public delivery.

## Close behavior and development permissions

The main window intercepts its own `performClose` and `close` actions. It does
not replace Flutter's window delegate. Hiding retains the window/engine and the
menu-bar item; explicit Quit remains an application termination request.

Release uses `com.memetics.lumalex`. Debug/test builds use
`com.memetics.lumalex.debug`, with a separate display name, preferences and
Keychain service so a test host cannot masquerade as the release application.

Local builds use ad-hoc signing unless a real signing identity is configured.
Its designated requirement changes when the executable is rebuilt. An enabled
old entry in Accessibility settings may therefore not authorize the current
binary. Use “Show current application in Finder” in Settings, remove the stale
entry, add the revealed application, enable access, then quit and reopen it.
Only a consistent certificate-backed signing identity can preserve permissions
across changed binaries; do not weaken the code-signing requirement or edit TCC
records to work around permission checks.
