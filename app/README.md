# LumaLex Windows application

This directory contains the Flutter application used by the Windows edition
of LumaLex. This repository supports Windows releases only; other client
editions are maintained separately.

Use the complete repository, not this directory alone. The application depends
on the Rust crates in `../crates`, the parser in `../vendor`, and the local
plugin overrides referenced by `pubspec.yaml`.

## Development

With the Windows prerequisites from the [repository README](../README.md)
installed, run these commands from this directory:

```powershell
flutter pub get
flutter test
flutter run -d windows
```

## Windows release artifacts

Flutter's `build/` directory contains generated intermediate files. It is not
the release delivery directory. To test, build and package the portable
Windows edition, run from this directory:

```powershell
.\windows\build_portable.ps1
```

The versioned ZIP and SHA-256 checksum are written to `windows/releases/`.
Keep `LumaLex.exe`, its DLLs and the `data` directory together when distributing
or running the extracted package. See the [Windows build guide](windows/README.md)
for the full prerequisites and validation checklist.

## Development boundaries

Reader resource and lifecycle policies are centralized in
`lib/platform/reader_platform_policy.dart`. Windows native integration lives
in `windows/`. See the [Windows development guide](docs/PLATFORM_MANAGEMENT.md)
before changing the reader, screen lookup or release process.

Dictionary files, local credentials, generated builds and release packages
must not be committed. Preserve the vendored dependency fixes and license
files needed by the Windows build.
