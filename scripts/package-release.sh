#!/bin/zsh
# Builds the app and writes dist/QuotaBar-<version>.zip plus its SHA-256 file.
# It verifies the signature of the app extracted from the zip and uploads nothing.
set -euo pipefail
cd "${0:A:h}/.."
./scripts/build.sh
bundle="$PWD/dist/QuotaBar.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle/Contents/Info.plist")"
archive="QuotaBar-$version.zip"
rm -f "dist/$archive" "dist/$archive.sha256"
ditto -c -k --keepParent --norsrc --noextattr --noqtn "$bundle" "dist/$archive"
# Record the bare file name so the checksum verifies from any download folder.
(cd dist && shasum -a 256 "$archive" > "$archive.sha256")
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/quotabar-release.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
ditto -x -k "dist/$archive" "$check_dir"
codesign --verify --deep --strict "$check_dir/QuotaBar.app"
(cd dist && shasum -a 256 -c "$archive.sha256")
printf 'Packaged %s\n' "$PWD/dist/$archive"
