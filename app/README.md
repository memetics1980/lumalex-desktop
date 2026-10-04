# LumaLex

LumaLex is a lightweight, local-first dictionary reader for MDX and MDD dictionaries.

## Release artifacts

Flutter uses the top-level `build/` directory for generated intermediate
files. It is not LumaLex's release delivery directory. Versioned application
packages are kept with their platform projects:

- Android APK and AAB: `android/releases/`
- iOS and iPadOS IPA: `ios/releases/`

Use `android/build_release.sh` or `ios/build_release.sh` so the release package
is built and copied to the correct platform directory automatically.

Android release builds require a private signing key. Copy
`android/key.properties.example` to `android/key.properties` and fill in the
keystore path and alias. The guarded script prompts for omitted passwords
without saving them; CI can provide the documented `LUMALEX_KEYSTORE_*`
environment variables. The release script refuses unsigned and Android Debug
certificates.

`android/build_release.sh` builds the signed arm64 APK used for direct
distribution. Pass `--with-aab` only when an Android App Bundle is needed for
a store upload.

On Android, open **词典 → 关于与诊断** to inspect the runtime, save a local
diagnostic report, or export and restore history, favorites, review progress,
and text scale. These exports never contain MDX/MDD dictionary data.

## Platform management

Reader behavior that differs because of WebView, memory, or lifecycle
constraints is centralized in `lib/platform/reader_platform_policy.dart`.
See [the platform management guide](docs/PLATFORM_MANAGEMENT.md) before making
a shared reader or release change.

## iOS and iPadOS dictionary folder

LumaLex creates a user-visible `Dictionaries` directory inside its Documents
container. In Files, place complete dictionary folders at:

`On My iPhone/iPad > LumaLex > Dictionaries`

Keep each `.mdx` file beside its matching `.mdd`, `.1.mdd`, and later media
volumes. LumaLex scans this directory at startup, when returning to the
foreground, or when the user chooses **Scan Folder**. The existing document
picker remains available through **Add from Another Location** for iCloud Drive
and third-party file providers. LumaLex keeps a security-scoped bookmark when
the provider supports persistent folder access. If it does not, LumaLex copies
the selected folder into its own `Dictionaries` directory without overwriting
an existing folder.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
