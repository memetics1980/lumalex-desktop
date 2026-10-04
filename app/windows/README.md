# LumaLex Windows portable build

The first Windows release targets 64-bit Windows 10 and Windows 11. It is a
portable folder rather than an installer: users extract the ZIP and launch
`LumaLex.exe` without administrator access.

Flutter desktop applications require the executable, DLLs and `data` directory
to stay together. “Portable” therefore means a self-contained extracted folder,
not a single standalone executable.

## Build prerequisites

- Flutter stable with Windows desktop enabled
- Visual Studio 2022 with **Desktop development with C++**
- Rust stable with the `x86_64-pc-windows-msvc` target
- Windows 10 or Windows 11 x64

From PowerShell or Command Prompt in the repository root:

```powershell
cd app
flutter pub get
.\windows\build_portable.bat
```

The script runs the Flutter tests, creates a release build, verifies the
required runtime files, and writes both the portable ZIP and its SHA-256 file
to `app\windows\releases\` in the repository.

Use `windows\build_portable.bat -SkipTests` only after the same source revision
has already passed the complete test suite.

## Release validation

Test the extracted ZIP, not the intermediate `build\windows` directory, at:

- 1920×1080 at 100%, 125% and 150% scaling;
- 2560×1440 at 125%, 150% and 175% scaling;
- 3840×2160 at 150%, 200% and 250% scaling;
- a touch-enabled Windows laptop in both mouse and touch workflows;
- snapped, maximized and cross-monitor window states.

Verify folder import, MDX/MDD resources, pronunciation audio, Windows system
speech, history, favorites, groups, backup export/import and relaunch state.
