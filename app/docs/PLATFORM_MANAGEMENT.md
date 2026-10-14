# Desktop development and release guide

This repository maintains the Windows and macOS desktop hosts together.
Keep shared application behavior in `lib/` and the Rust crates. Keep system
integration in the respective native host. Do not create permanent per-platform
branches or duplicate the entire application. Preserve the Windows WebView
plugin override and its local patches.

macOS is a development preview; see [its build guide](../macos/README.md).
Screen lookup events, popup HTML, AI and settings are shared. Windows uses
WebView2, UI Automation, Credential Manager and the system tray; macOS uses
WebKit, accessibility text/range/marker attributes, Keychain and the menu bar.
Keep native channel IDs distinct and preserve the existing preference keys.

## Ownership boundaries

- `lib/`: lookup, article rendering, dictionary groups, history, favorites,
  settings and floating-window controls.
- `lib/platform/reader_platform_policy.dart`: reader retention, resource-cache
  budgets and lifecycle decisions.
- `windows/`: Windows runner, WebView2 integration, system tray, global
  shortcuts, selected-text capture and native window behavior.
- `macos/`: macOS runner, WebKit popup, native speech, menu bar, global
  shortcuts, selection capture and Keychain.
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

## Shared desktop reader policy

- Matching dictionary documents are isolated frames inside a long-lived
  WebView2 host. Dictionary switching changes the visible frame and preserves
  its scroll position.
- The resource cache budget is 128 MiB; the largest individually cached
  resource is 16 MiB.
- The retained-reader limit is 3, including after a memory-pressure signal.
  The aggregate reader is the normal desktop rendering path.
- No separate adjacent-reader preload or automatic foreground-recovery
  reload is enabled by the desktop reader policy.
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

## Repository and release management

GitHub (`memetics1980/lumalex-desktop`) and Gitee (`memetics/lumalex-desktop`)
must have matching `main` commits and matching current release metadata and
attachments from build 96 onward. Pre-96 packages and their archive-only notices
remain on GitHub and are excluded from Gitee, including when attached to a newer
GitHub release. GitHub is the publication source; run `tools/sync_gitee.py` on the
local machine after source updates and release publication. The account owner
chose local-only synchronization: do not upload the Gitee token to GitHub or
configure cloud mirroring without a new explicit instruction. A failed local
sync must be resolved before publication is considered complete.

Use the same accepted binaries, filenames and SHA-256 files on both hosts.
Include the current packages for both desktop platforms on the shared release
page, clearly labeling different build numbers when one platform is unchanged.
Keep all historical releases intact on GitHub; Gitee starts with build 96 and
does not retain pre-96 release attachments or archive-only notices.

Finish uploading all assets to a GitHub draft, then publish it after acceptance.
With Python 3.12 and requests installed, run `python tools/sync_gitee.py` for
code-only synchronization. For a release, run
`python tools/sync_gitee.py --release-tag v0.1.0-build96`, substituting the
accepted release's tag, or use `--release-tag latest`. Run it again after any
release-note edits or asset additions. This is a local publication step, not a
background or cloud service.

The script reads `GITEE_TOKEN` from the process environment or the existing
ignored `.toolchains/gitee_token.txt` (also accepts `gitee-token.txt`). Optionally
set `GITHUB_TOKEN` for authenticated GitHub API requests. Never commit these
credentials. The script verifies branch commits, release metadata and downloaded
attachment hashes. Unexpected extra or changed attachments require inspection;
the script never deletes release files or force-pushes branches or tags.

Use `main` for both desktop platforms and short-lived feature branches. Run
shared Flutter and Rust checks on both Windows and macOS. A platform-specific
change must also pass its native build. A successful macOS build does not verify
Windows native integration; follow the Windows checklist on a Windows machine.

Publish platform artifacts under a shared version tag only after each artifact
passes its own release checklist. macOS preview releases may be published
separately while feature support catches up. Keep signing credentials out of Git.

### Unified desktop release pages

Use a platform-neutral tag such as `v0.1.0-build94` for both Windows and macOS.
Both `pubspec.yaml` and `app_version.dart` must match the published build number.
Keep platform names in asset filenames, not separate release tags/pages. When
adding a platform later, upload its verified assets to the existing shared
release and update the description for both platforms. Preserve already-tested
artifacts instead of renaming an old binary to pretend it is a newer version.
List each platform's system requirements, installation steps, signing status
and untested CPU architectures in the same release notes. Verify uploaded file
sizes and SHA-256 hashes before retiring a duplicate page.
