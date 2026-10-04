# LumaLex Windows

LumaLex is a local-first MDX/MDD dictionary reader for 64-bit Windows 10 and
Windows 11, built with Flutter and Rust.

This repository is maintained and distributed for Windows only. Other client
editions are maintained in separate repositories. The private repository is
[memetics1980/lumalex-windows](https://github.com/memetics1980/lumalex-windows).

## Features

- Import dictionary folders without copying or modifying the original MDX/MDD
  files. Matching and numbered MDD media volumes are discovered automatically.
- Render dictionary HTML, styles, scripts, fonts, images and pronunciation
  audio through a loopback-only content server and Microsoft Edge WebView2.
- Organize dictionaries into groups, choose the lookup scope, and switch
  dictionaries using the selector, arrow buttons or desktop sidebar.
- Keep search history, favorites, review progress and reading preferences
  locally, with data export and import.
- Use a configurable global shortcut to look up selected text in a floating
  window, play pronunciation audio and save words to the main favorites list.
- Optionally request AI explanations for a selected word in its captured
  context. Context availability depends on the source application's text
  accessibility support. Compatibility copy mode provides dictionary lookup
  without contextual AI explanations. AI requests are sent only when the
  user clicks the AI button.
- Choose whether closing the main window exits the application or hides it
  to the Windows system tray.
- Use a resizable interface with per-monitor DPI scaling and touch-friendly
  controls on supported Windows laptops.

Dictionary indexes and bounded lookup/resource caches reduce repeated work.
The Windows reader keeps a long-lived WebView2 host and switches dictionary
frames within it, avoiding a full reader recreation on ordinary dictionary
switches and window resizing.

## Run the portable edition

Extract the complete Windows ZIP into a writable folder and launch
`LumaLex.exe`. Keep the executable, DLLs and `data` directory together; the
portable edition is a complete folder, not a single executable. Installation
and administrator access are not required.

Microsoft Edge WebView2 Runtime is required. Dictionary files are not bundled;
import your own dictionary folders after launching the application. Preferences
and user records are stored in the current Windows user's application-data
area, not in the extracted program folder.

## Build on Windows

Use the complete repository: `app/windows` depends on the Flutter application
in `app`, the Rust crates in `crates`, and the patched parser in `vendor`.
Retain the local plugin overrides referenced by `app/pubspec.yaml` when
resolving dependencies.

Prerequisites:

- Windows 10 or Windows 11 x64
- Flutter stable with Windows desktop enabled
- Visual Studio 2022 with **Desktop development with C++**
- Rust stable with the `x86_64-pc-windows-msvc` target

From PowerShell in the repository root:

```powershell
cd app
flutter pub get
.\windows\build_portable.ps1
```

The script runs the Flutter tests, builds the release application, and writes
the portable ZIP and SHA-256 checksum to `app/windows/releases`.
See [the Windows build guide](app/windows/README.md) for release validation.

For development, run these commands from the repository root:

```powershell
cargo test -p dictionary-core
cd app
flutter pub get
flutter test
flutter run -d windows
```

## Repository layout

```text
app/lib/                    Flutter interface and application services
app/windows/                Windows runner, native integration and packaging
app/test/                   Flutter tests
app/rust_builder/           Flutter-to-Rust build integration
crates/dictionary-core/     Rust MDX/MDD engine
crates/dictionary-bridge/   Flutter-to-Rust API bridge
vendor/mdictlib/            Patched dictionary parser
```

See [the Windows development guide](app/docs/PLATFORM_MANAGEMENT.md) for
reader policies and change validation.

## Source and data boundaries

The local `.toolchains` directory, generated build output, release packages,
dictionary files, credentials and signing material are excluded from source
control. Do not commit API keys or personal application-data exports.

No dictionary data belongs in this source tree. Availability of an MDX/MDD
file does not imply permission to redistribute its contents. Keep third-party
license files with their corresponding vendored sources, including the
bundled Noto Sans SC font's license.
