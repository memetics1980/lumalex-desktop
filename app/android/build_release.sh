#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
release_dir="$script_dir/releases"
signing_properties="$script_dir/key.properties"
build_app_bundle=false

cd "$project_dir"

case "${1:-}" in
  "") ;;
  --with-aab) build_app_bundle=true ;;
  *)
    echo "Usage: $0 [--with-aab]" >&2
    exit 2
    ;;
esac

property_value() {
  local property_name="$1"
  [[ -f "$signing_properties" ]] || return 0
  sed -n "s/^${property_name}=//p" "$signing_properties" | tail -n 1
}

configured_store_file="$(property_value storeFile)"
configured_store_password="$(property_value storePassword)"
configured_key_alias="$(property_value keyAlias)"
configured_key_password="$(property_value keyPassword)"

release_store_file="${LUMALEX_KEYSTORE_FILE:-$configured_store_file}"
release_key_alias="${LUMALEX_KEY_ALIAS:-$configured_key_alias}"

if [[ -z "$release_store_file" || -z "$release_key_alias" ]]; then
  echo "Android release signing is not configured." >&2
  echo "Set storeFile and keyAlias in android/key.properties, or provide their LUMALEX_KEYSTORE_* variables." >&2
  exit 1
fi

if [[ "$release_store_file" = /* ]]; then
  resolved_store_file="$release_store_file"
else
  resolved_store_file="$script_dir/$release_store_file"
fi
if [[ ! -f "$resolved_store_file" ]]; then
  echo "Android release keystore not found: $resolved_store_file" >&2
  exit 1
fi

if [[ -z "${LUMALEX_KEYSTORE_PASSWORD:-}" && -z "$configured_store_password" ]]; then
  if [[ ! -t 0 ]]; then
    echo "Set LUMALEX_KEYSTORE_PASSWORD for a non-interactive release build." >&2
    exit 1
  fi
  read -r -s -p "Keystore password: " LUMALEX_KEYSTORE_PASSWORD
  printf '\n' >&2
  if [[ -z "$LUMALEX_KEYSTORE_PASSWORD" ]]; then
    echo "The keystore password cannot be empty." >&2
    exit 1
  fi
  export LUMALEX_KEYSTORE_PASSWORD
fi

if [[ -z "${LUMALEX_KEY_PASSWORD:-}" && -z "$configured_key_password" ]]; then
  if [[ ! -t 0 ]]; then
    echo "Set LUMALEX_KEY_PASSWORD for a non-interactive release build." >&2
    exit 1
  fi
  read -r -s -p "Key password (press Return to reuse the keystore password): " LUMALEX_KEY_PASSWORD
  printf '\n' >&2
  if [[ -z "$LUMALEX_KEY_PASSWORD" ]]; then
    if [[ -z "${LUMALEX_KEYSTORE_PASSWORD:-}" ]]; then
      echo "A separate key password is required when storePassword is saved in key.properties." >&2
      exit 1
    fi
    LUMALEX_KEY_PASSWORD="$LUMALEX_KEYSTORE_PASSWORD"
  fi
  export LUMALEX_KEY_PASSWORD
fi

version="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -n 1)"
build_name="${version%%+*}"
build_number="${version##*+}"

flutter build apk \
  --release \
  --target-platform android-arm64 \
  --split-per-abi \
  --no-pub

source_apk="$project_dir/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
destination_apk="$release_dir/LumaLex-$build_name-build$build_number-arm64-v8a.apk"

android_sdk="$(sed -n 's/^sdk.dir=//p' "$script_dir/local.properties" | head -n 1)"
apksigner="$(find "$android_sdk/build-tools" -type f -name apksigner | sort -V | tail -n 1)"
if [[ -z "$apksigner" ]]; then
  echo "Unable to locate apksigner in the configured Android SDK." >&2
  exit 1
fi

signing_report="$($apksigner verify --verbose --print-certs "$source_apk")"
if ! grep -q "Verifies" <<<"$signing_report"; then
  echo "The release APK signature could not be verified." >&2
  exit 1
fi
if grep -q "CN=Android Debug" <<<"$signing_report"; then
  echo "Refusing to publish an APK signed with the Android debug certificate." >&2
  exit 1
fi

mkdir -p "$release_dir"
install -m 0644 "$source_apk" "$destination_apk"
echo "Android release: $destination_apk"

if [[ "$build_app_bundle" = true ]]; then
  flutter build appbundle \
    --release \
    --no-pub

  source_bundle="$project_dir/build/app/outputs/bundle/release/app-release.aab"
  destination_bundle="$release_dir/LumaLex-$build_name-build$build_number.aab"
  install -m 0644 "$source_bundle" "$destination_bundle"
  echo "Android app bundle: $destination_bundle"
fi
