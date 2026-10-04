# LumaLex Windows

Windows development repository for LumaLex, a local-first MDX/MDD dictionary
reader built with Flutter and Rust. The private GitHub repository is
https://github.com/memetics1980/lumalex-windows.

## Windows build

Use the complete repository: `app/windows` depends on the Flutter application
in `app`, the Rust crates in `crates`, and the patched parser in `vendor`.
The shared project also retains its other platform files and local plugin
overrides needed to resolve Flutter dependencies.

Install Flutter, Visual Studio with Desktop development with C++, and Rust
with the `x86_64-pc-windows-msvc` target. From the repository root, run:

```powershell
cd app
flutter pub get
.\windows\build_portable.ps1
```

The build script runs the Flutter tests and writes the portable Windows ZIP to
`app/windows/releases`. The local `.toolchains` directory, build output,
dictionary files, credentials, and generated release packages are excluded
from source control. Import your dictionaries separately after launching the
application. See `app/windows/README.md` for Windows release validation.

Keep third-party license files with their corresponding vendored sources.

## Current state

The application selects dictionary folders without copying them into the
project, then opens MDX files through the Rust core. Android makes one stable,
app-private performance copy of each MDX at import time because SAF provider
descriptors have highly variable random-access latency on physical phones. The
copy is reused while source size and modification time match; large MDD media
volumes stay at their original location and are opened lazily.
Same-name MDD sidecars, including numbered volumes such as `name.1.mdd`, are
discovered automatically.

Each rendered dictionary receives an unguessable session under a loopback-only
HTTP origin. Its HTML, CSS, JavaScript, fonts, images and media all resolve
through that one origin and bounded, lazy MDD reads. This matches the browser
environment expected by interactive dictionary packages without maintaining
publisher-specific DOM patches. Inline and dynamically loaded local scripts
are supported. Approved CSS, JavaScript and font files beside the MDX override
same-named copies inside MDD volumes, so publisher-supplied theme and script
updates are honored. The document CSP still blocks external origins, frames, forms,
objects and file access; native navigation accepts only the current local
session and known dictionary schemes. Pronunciation links resolve from local
MDD data and play through the platform audio player. Sound-link clicks are
captured before publisher scripts can redirect them to optional online audio;
duplicate WebView navigation callbacks are coalesced and newer playback
requests safely supersede older ones.

The current application appearance is explicitly light. Dictionary pages receive
the same light color-scheme signal before publisher scripts run, preventing
packages with partial dark-mode support from placing pale text on a light host
background.

The Cambridge CDEPE package starts with all Chinese translations and primary
sense examples visible. Clicking definitions or examples no longer toggles
their translations, and clicking or double-clicking an already selected
part-of-speech tab no longer folds content. Unselected tabs still switch the
visible part of speech, while supplemental sections such as More examples and
Smart vocabulary remain independently collapsible and closed by default.

The Merriam-Webster `maldpe` package uses the same reading policy through its
own `MALDPE_*` settings and `.maldpe` navigation selectors: translations and
primary senses are visible, per-sentence translation toggles are disabled, and
the active part-of-speech tab no longer has click or double-click side effects.

Dictionary-authored headword links use a bounded back/forward navigation stack.
Each location records the query, selected dictionary and vertical scroll offset,
so revisiting a linked entry restores the page position. Dictionary selection is
kept in the named dropdown rather than sharing arrow controls with page history.
Double-clicking a word in rendered dictionary text performs the same local
headword navigation. Links, sound controls, navigation tabs, fold buttons and
form controls are excluded so the gesture does not replace publisher UI actions.

Each MDX receives a source-bound persistent headword index in the platform
application-support directory. Existing libraries migrate sequentially in the
background; a newly imported dictionary can resolve a raw-exact first result
from the candidate key block before that durable index is ready. Indexing starts
after a short idle window with the selected dictionary first and is cancelled
when foreground lookup or resource work arrives. Changes to the source
size or modification time automatically invalidate stale artifacts. Source MDX
and MDD files are never modified. Open dictionaries and lazy MDD volume handles
are also retained for the application lifetime. A bounded 128-entry lookup cache
makes linked-word back/forward navigation reuse decoded articles, while a 64 MB
resource cache reuses common styles, scripts, fonts, images and audio. The
selected dictionary is queried before the remaining library, and prefix
suggestions use a short debounce to avoid starting work for every keystroke.
The current and two nearby/recent dictionary pages form a bounded rendered LRU.
They are submitted directly to Chromium and retained across dictionary switches,
so returning to a recent dictionary is an instant visibility change rather than
another full document parse.

Mobile startup opens only the first usable enabled dictionary on the critical
path. The rest of a large library is restored sequentially after an idle delay,
pauses when a foreground lookup starts, and quietly fills the current multi-
dictionary result when each source becomes ready. Android also prewarms the
loopback origin and a short-lived headless Chromium reader after the first
Flutter frame; the real article reader is then created with its complete
security, mobile-viewport and selection-menu settings. A document becomes visible at WebView's first
committed frame, while text inspection, scroll observers and other compatibility
setup finish outside the first-paint path.

Decoded article HTML stays in a bounded process LRU. It is deliberately not
read from the old JSON disk cache: direct indexed MDX reads are faster than
parsing hundreds of KB of cached JSON for large entries. Query, MDX decoding
and WebView rendering emit separate debug timings, including preferred-result
readiness, local session creation, document construction/submission, first
visible frame and post-paint setup, so later performance work can be based on
measured bottlenecks.

The result view gives the selected dictionary nearly the full reading area.
On wide layouts a persistent right-hand result directory jumps directly to a
dictionary; compact layouts use a named dictionary sheet. Exact headwords and
MDict `@@@LINK` aliases always win; only a complete exact miss tries common
English inflections, followed by bounded spelling correction based on indexed
suggestions.
Desktop keyboard navigation supports Command/Ctrl-L to focus search,
Command/Ctrl-D to toggle the current favorite, Command/Ctrl-Left/Right for
article history, arrow keys plus Enter for suggestions, and Escape to dismiss
transient UI.

The local library persists each dictionary's display name, original path,
enabled state and display order. Persistent Apple security-scoped read grants
are implemented on macOS and iOS. iOS uses the system folder picker, retains
the selected folder for the process lifetime, and restores an implicit scoped
bookmark after relaunch so adjacent MDX/MDD files remain available. Android uses the system
Storage Access Framework folder picker: the app retains a read-only folder
grant, finds MDX files recursively, pairs same-name and numbered MDD volumes,
copies only MDX files into private high-speed storage, and exposes MDD resources
through process-local read-only descriptors. Final physical iOS/Windows device
validation remains a next implementation step. The search box also offers a small, bounded set of local
prefix completions without decoding definitions. Search history, favorites,
global reader text scale and simultaneous multi-dictionary lookup are also
stored locally. History and favorites support direct single-item deletion,
checkbox-based multi-select and select-all deletion, plus separately confirmed
clear-all actions.

No dictionary data belongs in this source tree. The ignore rules exclude
`.mdx` and `.mdd`, both because they can be very large and because availability
does not imply permission to redistribute their contents.

## Layout

```text
app/                       Flutter interface
crates/dictionary-core/    Rust MDX/MDD engine
docs/MVP.md                scope, API boundary, and milestones
```

## Local prerequisites

- A current Flutter stable SDK, including its desktop and mobile targets
- Rust stable with Cargo
- CocoaPods for the current Cargokit-based Rust bridge on iOS and macOS

## First checks after installing prerequisites

```sh
cargo test -p dictionary-core
cd app
flutter pub get
flutter run -d macos
flutter run -d android
```

## Android distribution builds

Do not distribute `app-debug.apk`: it includes Flutter's debug runtime,
kernel snapshot, diagnostics, and every CPU architecture. Configure a private
release key using `app/android/key.properties.example`, then use the guarded
release script:

```sh
cd app
android/build_release.sh
```

For almost all current Android phones, install the versioned arm64 APK in
`android/releases/`. Pass `--with-aab` when a store-delivery bundle is needed.
The script verifies the APK signature and refuses an Android Debug certificate.

## Windows portable builds

The Windows target is a portable x64 folder for Windows 10 and Windows 11. It
does not require installation or administrator access, but `LumaLex.exe` must
remain beside its DLL files and `data` directory.

On a Windows development machine with Flutter, Visual Studio C++ and Rust
installed, run:

```powershell
cd app
windows\build_portable.bat
```

The versioned ZIP and SHA-256 checksum are written to
`app\windows\releases\`. See
[`app/windows/README.md`](app/windows/README.md) for prerequisites and the
1080p/4K, High DPI, touch and WebView2 release checklist.

The platform runners are already checked into the local project. To refresh the
generated bridge after changing its public Rust API, run this command from the
project root:

```sh
flutter_rust_bridge_codegen generate \
  --rust-root crates/dictionary-bridge \
  --rust-input crate::api \
  --dart-output app/lib/src/rust \
  --dart-entrypoint-class-name DictionaryRust \
  --no-web
```

## Next implementation step

Validate the loopback content origin, restored iOS folder grants, and audio
playback on physical Android, iOS, macOS, and Windows devices. The exact resource and security constraints are in
[docs/MVP.md](docs/MVP.md).
