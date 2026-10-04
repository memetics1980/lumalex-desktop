LumaLex for Windows - Portable Edition
=====================================

System requirements
-------------------
- 64-bit Windows 10 or Windows 11
- Microsoft Edge WebView2 Runtime (normally already present on current systems)

Run
---
1. Extract the complete ZIP archive to a normal writable folder.
2. Keep LumaLex.exe, its DLL files, and the data folder together.
3. Double-click LumaLex.exe. Administrator access and installation are not required.

Dictionary and settings data
----------------------------
- Imported MDX/MDD files stay in their original folders; do not move them after import.
- Preferences, history, favorites, groups, and review progress are stored in the
  current Windows user's application-data area, not inside this program folder.
- Use LumaLex's data export feature before moving to another computer.

Touch and High DPI
------------------
- The interface uses Windows per-monitor DPI scaling and can move between displays
  with different scaling values.
- Common controls keep touch-friendly hit targets on touch-enabled laptops.

Troubleshooting
---------------
- If Windows SmartScreen appears, verify the ZIP SHA-256 supplied with the release.
  A privately distributed unsigned build may still show a warning.
- If dictionary pages are blank, install or repair Microsoft Edge WebView2 Runtime.
