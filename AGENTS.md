# LumaLex repository instructions

## Source and releases

- Maintain matching `main` branches on GitHub (`memetics1980/lumalex-desktop`)
  and Gitee (`memetics/lumalex-desktop`). Sync every approved source update to
  both hosts and verify their commit IDs before reporting completion.
- Publish accepted desktop builds on GitHub first, then sync the same tag,
  source commit, title, bilingual notes, prerelease status, filenames and exact
  asset bytes to Gitee, excluding pre-96 assets and their archive-only notices.
  Do not rebuild separately for each hosting platform.
- Include the current Windows and macOS packages and their checksums on the
  shared release page. Clearly label different platform build numbers. Reuse
  an unchanged accepted platform package when only the other platform updates.
- Preserve historical releases on GitHub. Gitee starts with build 96; do not
  import older releases, packages or their archive-only notices, even when
  those assets are attached to a newer GitHub release. Never publish experimental
  branches or private dictionary data as an official release.
- Validate the packaged build and obtain the user's acceptance before releasing
  a new application version. Normal source/documentation synchronization does
  not require a new build or another release approval.
- Run `tools/sync_gitee.py` locally for mirroring; the user chose local-only
  synchronization. Do not upload the Gitee token to GitHub, configure an Actions
  secret, or enable cloud mirroring unless the user explicitly changes this
  preference. Verify a successful local sync, not merely a GitHub upload. A
  failed mirror is an incomplete publication: resolve it or report the blocker.
- Keep credentials out of source, logs and release files. Read tokens from
  environment variables or the existing ignored local credential files.
- Retain MIT licensing for LumaLex's own code and existing component licenses.

## Document quality

For every request creating or editing a `.docx`, use the `documents` skill,
render the final document with the bundled `render_docx.py`, and inspect every
page for clipping, overlap, table/image problems and page-break defects.
If rendering is unavailable, state that visual verification was not completed.
On Windows, if rendering stalls, use installed `soffice.com` with a unique
writable LibreOffice profile, convert to PDF, then rasterize and inspect all
pages. Do not skip this gate.
