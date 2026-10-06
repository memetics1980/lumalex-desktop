# LumaLex for macOS: installation and use

[简体中文](MACOS_GUIDE.zh-CN.md) | [English](MACOS_GUIDE.en.md) · [Project overview](../README_EN.md)

## Download and install

Download the DMG or ZIP from [macOS build 88](https://github.com/memetics1980/lumalex-desktop/releases/tag/v0.1.0-build88). Requires macOS 12+. The package includes Apple Silicon and Intel slices. Apple Silicon has been tested; Intel hardware has not yet been tested.

1. Open the DMG, drag `LumaLex.app` into Applications, then eject the disk image. Alternatively, extract the ZIP and copy the app into Applications.
2. Launch the app from Applications. Before updating, quit the previous version with `⌘Q`, then replace it.
3. This preview is ad-hoc signed, without Developer ID signing or Apple notarization. If macOS cannot verify the developer, check the download source and follow [Apple's instructions](https://support.apple.com/en-us/102445) to confirm Open Anyway in System Settings → Privacy & Security. Do not disable system-wide protection.
4. Import your own MDX/MDD folder in the Dictionaries page. Commercial dictionaries are not bundled; keep the original files and companion resources in place.

Matching SHA-256 files are supplied. Run `shasum -a 256 filename` and compare the result with the checksum file.

## Screen lookup and Accessibility

Enable screen lookup in Settings (设置 → 屏幕取词). The default global shortcut is `⌘⌥L`; `⌘⇧L` and `⌥Q` are also offered. Choose another combination if there is a conflict.

Add the installed `LumaLex.app` to System Settings → Privacy & Security → Accessibility and enable it. “Show current application in Finder” (在 Finder 中显示当前应用) in LumaLex settings locates the running copy. Quit with `⌘Q` and reopen after granting access.

Select a word in browser body text and press the shortcut. Edge / Chrome may take about two extra seconds to initialize accessibility on the first request. Contextual AI is available when the source exposes nearby context. If only copying is possible, the popup indicates compatibility copy mode, with dictionary lookup only. Copy mode updates the clipboard. Password fields are excluded; capture does not use OCR.

After an update, an old Accessibility entry may not authorize the changed ad-hoc-signed binary. Remove the old entry, add and enable the current application, then quit and reopen. The debug/test edition has a separate identifier and permission state.

## Popup and menu bar

- Switch dictionaries with the name menu or arrows; switching stays within the selected group. Boundary arrows are disabled.
- Drag the top word title or empty header area to move the popup.
- Automatic mode closes five seconds after the pointer leaves; pinning keeps it visible. Pending AI pauses automatic closure.
- Pronunciation depends on the dictionary's resources. Favorites are shared with the main window.
- Choose hide-to-menu-bar in Settings to keep the app running after clicking X, then restore it from the menu-bar icon. Screen lookup requires background operation. Quit completely through the menu bar or `⌘Q`.

## Contextual AI

Configure a compatible API endpoint, model and key in Settings, then save and test. API keys are stored in macOS Keychain. Click AI in a popup with available context to analyze it; configuration alone does not automatically analyze selections.

Requests send the selected word and up to about 500 characters of nearby context to your configured provider. Connection testing also sends a sample request. Ordinary dictionary lookup works offline and does not upload whole dictionaries. Avoid sending sensitive text and verify AI output against a dictionary.

## Data and limitations

Preferences, indexes and learning records live in the user's Application Support directory, outside the app bundle. Replacing the app generally preserves them. Windows and macOS do not automatically synchronize data or credentials. Export learning data when moving computers, prepare dictionary files separately and configure AI again.

For shared dictionary, group, favorite, review and learning-data operations, see the [full user guide](USER_GUIDE.en.md). Use this guide for macOS installation, permissions, menu-bar behavior and global shortcuts.

Accessibility support varies across browsers, documents and PDF readers; some content only supports compatibility copying. Intel hardware and all supported macOS releases have not been tested, and this preview is not Apple-notarized.
