#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
release_dir="$script_dir/releases"
export_method="${1:-development}"

cd "$project_dir"

version="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -n 1)"
build_name="${version%%+*}"
build_number="${version##*+}"

flutter build ipa \
  --release \
  --no-pub \
  --export-method "$export_method"

source_ipa="$project_dir/build/ios/ipa/LumaLex.ipa"
destination_ipa="$release_dir/LumaLex-$build_name-build$build_number-$export_method.ipa"

mkdir -p "$release_dir"
install -m 0644 "$source_ipa" "$destination_ipa"

echo "iOS/iPadOS release: $destination_ipa"
