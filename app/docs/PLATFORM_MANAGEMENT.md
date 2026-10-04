# Platform management

LumaLex has one Flutter application but multiple client platforms. Shared
features must not silently change a platform-specific stability policy.

## Ownership boundaries

| Area | Owner | Examples |
| --- | --- | --- |
| Shared product behavior | `lib/` | lookup, article parsing, reader controls, history |
| Reader constraints | `lib/platform/reader_platform_policy.dart` | WebView retention, resource-cache budgets, reveal timing, foreground recovery |
| Android integration | `android/` and Android-only services | Storage Access Framework, selected-text lookup window, Android lifecycle and release APK |
| iOS integration | `ios/` and iOS-only services | security-scoped files, WebKit recovery and release IPA |

Do not add a reader lifecycle or memory `Platform.is…` check to a screen or
service when it belongs in `ReaderPlatformPolicy`. Platform APIs that have no
shared equivalent, such as Android SAF and iOS bookmarks, remain in their
platform services.

## Shared dictionary organization

Android and iOS/iPadOS expose the same optional dictionary-grouping behavior.
Group names, colors, order, and the active lookup scope are shared Flutter
product behavior; each library entry stores only a stable group ID. Platform
file access remains unchanged: Android continues to use SAF-backed sources and
iOS continues to use its Dictionaries directory or security-scoped imports.
Creating, renaming, recoloring, reordering, or deleting a group never moves,
renames, or deletes the underlying MDX/MDD files.

Disabled or temporarily inaccessible dictionaries remain visible in the
management screen. Group headers therefore show both the number currently
available for lookup and the total number of managed records. The lookup
scope selector counts only enabled, accessible dictionaries.

## Current reader policy

| Policy | Android | iOS | Desktop |
| --- | ---: | ---: | ---: |
| Normal lookup WebViews | 1 aggregate WebView | up to 2 recently used WebViews | up to 3 retained WebViews |
| Dictionary tab switch | show a preloaded iframe | switch retained reader; third reuses the LRU native slot | switch retained reader |
| Preload an extra retained reader | legacy fallback only | no | yes |
| Dictionary resource cache | 64 MiB | 16 MiB | 64 MiB |
| Largest cached resource | 8 MiB | 2 MiB | 8 MiB |
| Reveal after text-scale setup | yes | no | no |
| Recover reader after foreground | no | yes | no |
| Release transient resources on memory pressure | yes | yes | yes |
| Native WebView keep-alive | yes | no | no |

The iOS limits and foreground recovery protect WKWebView under memory pressure.
While active, iOS retains only the selected dictionary and the most recently
visited dictionary. It does not preload the second WKWebView. A third visited
dictionary replaces the document in the least recently used of two stable
WKWebView slots instead of allocating another native platform view. Article
results remain in the bounded lookup cache, and a separate bounded
`(query, dictionary) -> scroll offset` cache restores the evicted reader to its
previous position. A memory-pressure event or a real background transition
immediately disposes the extra slot and trims the retained set to the selected
reader; returning to the foreground restores the two-reader allowance without
allocating another WKWebView until the next explicit switch. Changing the
global text scale clears evicted-reader offsets because pixel positions are no
longer valid after document reflow.
An Android-only rendering improvement must be represented as an Android policy
value, not as a change to the iOS reader timeline.

iOS foreground recovery first verifies the loopback content server and the
visible document. It reloads only after the server was restarted, the document
health check fails, or WebKit terminates the content process. Repeated content
process terminations are bounded; the reader falls back to simplified text
instead of entering an automatic reload loop. Memory-pressure and recovery
events are kept in a bounded, local-only diagnostic log.

Android's normal lookup path waits for the enabled dictionaries to finish,
then loads every matching document as an isolated iframe inside one aggregate
WebView. The existing dictionary selector remains the user-facing tab control;
switching it only hides and shows already loaded documents and restores a
per-dictionary scroll position. This aggregate policy is Android-only. iOS
uses its bounded two-reader LRU and keeps the foreground-recovery path.

The Android launcher may restore only the first usable dictionary while its
empty home screen starts. Before any actual word lookup, the shared lookup
entrypoint cancels background warmup, restores every remaining enabled
dictionary, and only then creates the aggregate document. In-flight restore
work is deduplicated by dictionary path. This keeps home startup responsive
without allowing an immediate cold lookup to render `1/1` and then reload as
`1/N`.

Android exposes `ProcessTextActivity` as a `text/plain` `PROCESS_TEXT` target,
so standard system selection menus can show “LumaLex 查词”. The activity uses
a translucent, movable and resizable application window backed by the normal
Flutter/Rust lookup stack. It deliberately does not request
`SYSTEM_ALERT_WINDOW`: the source application remains visible behind the
lookup window, and tapping that outside area closes the window. Movement and
resizing use native screen coordinates so moving the Activity cannot feed
back into its own gesture delta. Fold/unfold and other display changes retain
the relative placement when possible, then clamp the window into the new
system-bar-safe display area. The normal launcher activity and all iOS
entrypoints remain unchanged.

The selected-text reader never overlays persistent actions on its article.
Text size and favorite actions live beside maximize in the 50 dp title bar;
the native drag surface covers only the title's left portion and leaves those
three Flutter tap targets unobstructed. Search and lookup back/forward actions
share one compact 44 dp row. Tapping `Aa` temporarily replaces that row with
`− / percentage / +`, without consuming more height. The dictionary-selector
row remains an uninterrupted horizontal gesture surface for switching results,
and only the native resize handle occupies the article's bottom-right corner.

Unlike the normal launcher, which restores one dictionary first for a fast
home-screen startup, the selected-text activity restores every enabled
dictionary before submitting its initial word. Android then performs one
aggregate lookup and creates one aggregate document, avoiding a visible
`1/1` first render followed by a second `1/N` render as background dictionaries
become available.

The launcher and selected-text activity are separate Flutter engines. History,
favorites, review cards, and text scale use the same uncached persistent store,
but each `HomePage` still has an in-memory snapshot for rendering. Whenever an
activity returns to the foreground, it reloads that shared record state after a
short write-settling delay. A local-mutation generation guard prevents an older
foreground read from overwriting a record changed by the current UI while that
read was in flight. This makes words looked up or favorited in the floating
window appear in an already-running launcher without restarting the app.

The retained-reader list remains the fallback and desktop LRU eviction list,
not a widget-order list. Render retained readers in stable dictionary-library
order so selecting a tab does not move or reattach platform views.

Android still reads `ActivityManager.memoryClass` and `isLowRamDevice` for the
legacy per-dictionary fallback:

- low-RAM devices or an app memory class of at most 192 MiB retain 2 readers;
- normal devices retain 3 readers;
- an app memory class of at least 512 MiB retains 5 readers.

When Flutter receives Android's memory-pressure signal, LumaLex releases the
decoded dictionary-resource cache and shrinks the reader LRU to the selected
page. After the application returns to the foreground, it restores the device
tier and resumes bounded background preloading.

## Change and release procedure

1. Classify a change before coding: `shared behavior`, `reader policy`, or
   `native integration`.
2. For reader-policy changes, update the policy test and this matrix.
3. Run `flutter test` for every shared-Dart change.
4. Validate the affected real device path:
   - Android: import through SAF, text scale, dictionary switching, a large
     article, and `PROCESS_TEXT` launch from another app's selection menu.
   - iOS: large article, dictionary switching, lock/background/resume, and
     repeated foreground recovery.
5. Increment the `pubspec.yaml` build number only when producing a delivery.
   The platform release scripts copy artifacts to `android/releases/` and
   `ios/releases/`; do not hand-edit generated platform version files.

## Delivery rule

Android and iOS may ship at different times. A shared-code change is eligible
for a platform release only after that platform's checklist passes. Do not use
an Android release test as evidence that the iOS WebKit path is safe, or vice
versa.
