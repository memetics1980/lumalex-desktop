<img src="app/assets/branding/lumalex-icon-ui.png" alt="LumaLex app icon" width="96" height="96">

# LumaLex Desktop

[简体中文](README.md) | [English](README_EN.md)

Keep your dictionaries local, look up words without leaving your reading, and use AI to understand a word in context.

LumaLex is a desktop MDX/MDD dictionary reader built with Flutter and Rust. This repository maintains Windows and macOS together, sharing application code and the Rust dictionary engine.

| Platform | Download and status |
| --- | --- |
| Windows 10/11 x64 | [Windows portable build 94](https://github.com/memetics1980/lumalex-desktop/releases/tag/v0.1.0-build94-windows); extract the entire archive |
| macOS 12+ | [macOS preview build 88](https://github.com/memetics1980/lumalex-desktop/releases/tag/v0.1.0-build88); DMG and ZIP available |

The macOS package is Universal (Apple Silicon / Intel). It has been tested on Apple Silicon; Intel hardware has not yet been tested. This preview is ad-hoc signed, without Developer ID signing or Apple notarization, so first launch may require confirmation in System Settings. Both hosts share settings, dictionary navigation and popup content. macOS supports menu-bar persistence, global lookup shortcuts, accessibility-based selection/context capture, Keychain and contextual AI. Capture depends on the source app. Screenshots below show Windows.

LumaLex does not bundle or distribute commercial dictionaries. Once you import your own dictionaries, ordinary lookup works offline. Contextual AI explanations are optional, require separate configuration, and run only on request.

[Download Windows portable edition](https://github.com/memetics1980/lumalex-desktop/releases/tag/v0.1.0-build94-windows) · [Download macOS preview](https://github.com/memetics1980/lumalex-desktop/releases/tag/v0.1.0-build88) · [macOS installation and use](docs/MACOS_GUIDE.en.md) · [User guide](docs/USER_GUIDE.en.md) · [中文使用说明](docs/USER_GUIDE.zh-CN.md) · [Windows build guide](app/windows/README.md)

Click a screenshot to view the full-resolution original. Dictionaries and reading materials shown are examples and are not bundled with the app; AI output is an example, not a guaranteed answer.

## Highlights

### Offline dictionaries and multi-dictionary lookup

Read MDX entries with MDD images, fonts and audio while preserving dictionary-authored formatting and interaction where compatible. Imported dictionary files stay in their original folders rather than being copied into the application directory.

[![Main-window dictionary lookup and desktop sidebar](docs/images/main-lookup.png)](docs/images/main-lookup.png)

Main-window lookup: dictionary-authored formatting, pronunciation controls and a desktop dictionary sidebar.

Organize dictionaries into groups and restrict lookup and switching to one group, or choose all dictionaries or ungrouped dictionaries. Use the dropdown, previous/next buttons, keyboard shortcuts or the left-side list in wide windows to change dictionaries.

[![Dictionary groups and enabled dictionaries](docs/images/dictionary-groups.png)](docs/images/dictionary-groups.png)

Dictionary management: groups, enabled status, ordering and folder import.

### A lookup popup that keeps you in your reading

Select a word or phrase in another application and press the lookup shortcut to open a popup near the pointer. The popup offers:

- `[◀] [Current dictionary ▾] [▶]` controls, with a scrollable grouped menu behind the dictionary name.
- Headword and example audio when the imported dictionary includes the corresponding resources.
- A star button that saves words to the main application's favorites.
- A main-window button to continue the current lookup in the full interface.
- Click to switch between the original word and verified related forms. Explicit switching updates the current query, favorite target and main-window handoff, while AI retains the original word and sentence as context.
- Mouse or touch dragging from the empty top area so the popup need not cover the source text.
- Automatic closing or persistent display: it stays open while the pointer is inside and closes five seconds after it leaves. Persistent mode disables automatic closing, and an active AI request also pauses it.

[![Selected-word popup with contextual AI while reading in a browser](docs/images/screen-lookup-browser.png)](docs/images/screen-lookup-browser.png)

Browser reading example: select “moves” and compare the contextual AI explanation with the local dictionary in the same popup.

### Contextual AI: the meaning used in this sentence

A word can have several meanings. LumaLex sends the selected word and nearby context to a model configured by the user, helping identify the part of speech and meaning used in the current sentence instead of listing every possible definition.

For example, `voice` behaves differently in “a beautiful voice” and “voice their concerns.” This illustrates the purpose of contextual analysis, not a fixed AI response.

Results include the lemma, part of speech, English and Chinese meanings, contextual evidence, a confidence level and an ambiguity note. Keep the local dictionary available to check the model's interpretation.

[![Contextual AI analysis of touch in a Word document](docs/images/ai-context-word.png)](docs/images/ai-context-word.png)

Word document example: AI interprets “human touch” as a personal or human quality. Supported document applications can also provide context; availability depends on their text interfaces.

**Limitations**: contextual AI requires usable captured context. Some PDF readers only allow copying the selected word; offline lookup still works in that mode, but contextual AI is unavailable. Screen lookup is not OCR and cannot read every application. AI can make mistakes and should not replace dictionary verification.

### Desktop reading and learning

- Resizable, maximized and snapped windows with High DPI support.
- Touch-friendly hit targets for common controls.
- A bundled Noto Sans SC UI font with its license retained.
- Local history, favorites, review records, and learning-data export/restore.
- A choice between exiting when the main window closes or continuing in the Windows system tray / macOS menu bar.

## Quick start

**macOS:** Open the downloaded DMG and drag `LumaLex.app` into Applications, then launch it there. Alternatively, extract the ZIP and copy the app into Applications. See the [macOS guide](docs/MACOS_GUIDE.en.md) for first launch and Accessibility permission.

**Windows:**

1. Extract the complete portable Windows package into a writable folder and run `LumaLex.exe`. Keep the DLLs and `data` directory beside it.
2. Open the dictionary page and import a folder containing your MDX files and matching MDD resources.
3. Enter a word on the lookup page, choose the lookup scope, and switch dictionaries to compare entries.
4. Enable global screen lookup in Settings. The default shortcut is `Ctrl + Alt + L`; choose another offered combination or record a custom Windows shortcut if it conflicts.
5. For AI, configure the compatible API base URL, model ID and API key in Settings, save them and test the connection. Open a popup from selected text and explicitly click its AI button.

See the [user guide](docs/USER_GUIDE.en.md) for configuration, popup controls, PDF limitations and troubleshooting. English documentation does not change or translate the application's current UI labels; the guide includes Chinese labels where useful.

## Data and privacy

- Local dictionary lookup does not require AI. Enabling AI does not upload entire dictionary files.
- API keys use the current Windows user's secure credentials or macOS Keychain. Clicking AI sends the selected word and up to approximately 500 characters of nearby context to the configured service. Testing the connection also sends a sample request.
- Do not send private or confidential text to an external AI service. The provider determines its own data-handling and billing terms.
- Compatibility copy mode updates the system clipboard. Password fields are excluded from screen lookup.
- Settings and learning records live in each platform's user application-data directory (Windows AppData / macOS Application Support); the platforms do not automatically synchronize. “Portable” means no program installation, not that all user data lives beside the executable.
- Learning-data exports contain history, favorites, review progress and reading text scale, not MDX/MDD files, the dictionary library or AI credentials. Prepare your dictionaries separately and configure AI again on another computer.

## Development and build

**macOS:** Install Flutter stable, Xcode, CocoaPods and Rust stable, then run `cd app && bash macos/build_release.sh`. It checks and builds the app and produces DMG, ZIP and SHA-256 files in `app/macos/releases`. See the [macOS build guide](app/macos/README.md).

**Windows:**

Use Windows 10/11 x64, Flutter stable with Windows desktop enabled, Visual Studio 2022 with **Desktop development with C++**, and Rust stable with the `x86_64-pc-windows-msvc` target. Dictionary rendering requires Microsoft Edge WebView2 Runtime.

Keep the complete repository and the local dependencies referenced by `app/pubspec.yaml`. From the repository root:

```powershell
cd app
flutter pub get
.\windows\build_portable.ps1
```

The script runs the Flutter tests and creates a portable ZIP plus a SHA-256 checksum in `app/windows/releases`. Generated packages are not committed as source files. Download published portable packages from [Releases](https://github.com/memetics1980/lumalex-desktop/releases/latest), not GitHub's source-code ZIP.

For development and tests:

```powershell
cargo test -p dictionary-core
cd app
flutter pub get
flutter test
flutter run -d windows
```

[Application development notes](app/README.md) · [Windows development and release guide](app/docs/PLATFORM_MANAGEMENT.md)

## Layout and licensing boundaries

```text
docs/                      Chinese and English user guides
app/lib/                   Interface and application services
app/windows/               Windows integration and packaging
app/macos/                 macOS integration and packaging
app/test/                  Flutter tests
app/rust_builder/          Flutter / Rust build integration
crates/dictionary-core/    MDX/MDD engine
crates/dictionary-bridge/  Flutter / Rust API bridge
vendor/mdictlib/           Patched dictionary parser
```

Toolchains, build caches, portable packages, dictionary data and sensitive configuration are excluded from source control. Retain third-party dependency and font licenses. Possessing a dictionary file does not grant redistribution rights; check its terms before using or sharing it.
