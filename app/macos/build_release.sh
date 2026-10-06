#!/bin/bash
set -euo pipefail

macos_dir="$(cd "$(dirname "$0")" && pwd)"
app_dir="$(cd "$macos_dir/.." && pwd)"
repo_dir="$(cd "$app_dir/.." && pwd)"
cd "$app_dir"

if [[ "${1:-}" != "--skip-build" ]]; then
  if [[ $# -ne 0 ]]; then echo 'Usage: bash macos/build_release.sh [--skip-build]' >&2; exit 2; fi
  flutter pub get
  flutter analyze
  flutter test
  flutter build macos --release
  (cd macos && xcodebuild -workspace Runner.xcworkspace -scheme Runner \
    -configuration Debug -destination 'platform=macOS' -only-testing:RunnerTests test)
fi

bundle="$app_dir/build/macos/Build/Products/Release/LumaLex.app"
plist="$bundle/Contents/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
expected="$(sed -n 's/^version: *//p' pubspec.yaml)"
[[ "$expected" == "$version+$build" ]] || { echo 'Built app version does not match pubspec.yaml' >&2; exit 1; }
codesign --verify --deep --strict "$bundle"
architectures="$(lipo -archs "$bundle/Contents/MacOS/LumaLex")"
if [[ "$architectures" == *arm64* && "$architectures" == *x86_64* ]]; then
  architecture=universal
elif [[ "$architectures" == arm64 ]]; then
  architecture=arm64
elif [[ "$architectures" == x86_64 ]]; then
  architecture=x64
else
  echo "Unexpected architecture: $architectures" >&2; exit 1
fi
# Every native framework must support each advertised application architecture.
while IFS= read -r -d '' binary; do
  if file -b "$binary" | /usr/bin/grep -q 'Mach-O'; then
    slices="$(lipo -archs "$binary")"
    for arch in $architectures; do
      [[ " $slices " == *" $arch "* ]] || { echo "Missing $arch: $binary" >&2; exit 1; }
    done
  fi
done < <(find "$bundle/Contents/Frameworks" -type f -print0)

name="LumaLex-$version-build$build-macos-$architecture"
output="$macos_dir/releases"
mkdir -p "$output"
staging="$(mktemp -d "${TMPDIR:-/tmp}/lumalex-release.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
mkdir "$staging/$name"
ditto "$bundle" "$staging/$name/LumaLex.app"
cp "$macos_dir/INSTALL_README.txt" "$staging/$name/README.txt"
mkdir "$staging/$name/Docs"
cp "$repo_dir/docs/MACOS_GUIDE.zh-CN.md" "$repo_dir/docs/MACOS_GUIDE.en.md" "$staging/$name/Docs/"
# ditto preserves bundle symlinks and code signatures. Distribution files are
# outside the signed app bundle; never insert user settings or dictionaries.
ditto -c -k --sequesterRsrc --keepParent "$staging/$name" "$output/$name.zip"
ln -s /Applications "$staging/$name/Applications"
hdiutil create -volname "LumaLex $version" -srcfolder "$staging/$name" \
  -ov -format UDZO "$output/$name.dmg"
(cd "$output" && shasum -a 256 "$name.zip" > "$name.zip.sha256.txt" && \
  shasum -a 256 "$name.dmg" > "$name.dmg.sha256.txt")
echo "Release packages: $output/$name.{dmg,zip}"
