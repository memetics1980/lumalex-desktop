# Windows development and release guide

This guide covers the Windows edition maintained in this repository. Other
client editions have separate repositories and release procedures.

## Ownership boundaries

- `lib/`: lookup, article rendering, dictionary groups, history, favorites,
  settings and floating-window controls.
- `lib/platform/reader_platform_policy.dart`: reader retention, resource-cache
  budgets and lifecycle decisions.
- `windows/`: Windows runner, WebView2 integration, system tray, global
  shortcuts, selected-text capture and native window behavior.
- `../crates/` and `../vendor/`: Rust dictionary engine, API bridge and patched
  dictionary parser.

Keep reader lifecycle and memory policy in `ReaderPlatformPolicy` rather than
scattering new platform checks through screens and services. Preserve local
plugin overrides and their documented patches when updating dependencies.

## Dictionary organization

Dictionary group names, colors, order and the active lookup scope are stored
locally. Each dictionary record references a stable group ID. Creating,
renaming, recoloring, reordering or deleting a group does not move, rename or
delete the underlying MDX/MDD files.

Disabled or temporarily inaccessible dictionaries remain visible in the
management screen. Lookup scope counts include only enabled, accessible
dictionaries. Dictionary switching must respect the selected group scope.

## Windows reader policy

- Matching dictionary documents are isolated frames inside a long-lived
  WebView2 host. Dictionary switching changes the visible frame and preserves
  its scroll position.
- The resource cache budget is 128 MiB; the largest individually cached
  resource is 16 MiB.
- The retained-reader limit is 3, including after a memory-pressure signal.
  The Windows aggregate reader is the normal rendering path.
- No separate adjacent-reader preload or automatic foreground-recovery
  reload is enabled by the Windows reader policy.
- Dictionary selection and layout changes must not recreate the native
  reader unnecessarily. Verify that resizing the window or visiting settings
  and returning to lookup preserves the article.

## Screen lookup and AI

Selected-text capture depends on the source application's accessibility and
copy support. Test ordinary browser pages, browser PDF documents and external
document readers separately. A failure to capture text must not terminate the
application or remove its tray icon.

Compatibility copy mode supports dictionary lookup without contextual AI
explanations. Offer contextual AI only when a usable context was captured;
send the request only after the user explicitly clicks the AI button.

Verify that floating-window favorites appear in the main application's list,
pronunciation works on the first click, and dictionary arrows stay inside the
active group. In automatic-close mode, the window remains open while the
pointer is inside and closes five seconds after it leaves. An in-flight AI
request must not be interrupted by automatic closing.

## Change and release procedure

1. Classify the change as application behavior, reader policy or Windows native
   integration, and update the relevant tests and documentation.
2. Run `flutter test` for application-code changes and
   `cargo test -p dictionary-core` for dictionary-engine changes.
3. Validate the affected Windows path: folder import, large dictionary entries,
   dictionary switching, mouse and touchpad scrolling, pronunciation, favorites,
   system tray, screen lookup and AI when applicable.
4. Check compact, maximized and snapped windows, touch-enabled controls, and
   per-monitor DPI changes. A compact Windows layout is still a Windows client.
5. Increment `pubspec.yaml`'s build number when producing a new application
   delivery; documentation-only changes do not require a new build number.
6. Run `windows/build_portable.ps1` from `app/`. Deliver the versioned ZIP and
   checksum from `app/windows/releases`, not the intermediate build directory.

Test the extracted package against the [Windows release checklist](../windows/README.md).
Do not use a successful development launch as a substitute for validating the
portable release package.
