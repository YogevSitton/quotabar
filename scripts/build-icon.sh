#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
source_icon="$PWD/Assets/QuotaBar.png"
icon_work="$(mktemp -d "${TMPDIR:-/tmp}/quotabar-icon.XXXXXX")"
trap 'rm -rf "$icon_work"' EXIT
iconset="$icon_work/QuotaBar.iconset"
mkdir -p "$iconset"
for points in 16 32 128 256 512; do
    sips -z "$points" "$points" "$source_icon" --out "$iconset/icon_${points}x${points}.png" >/dev/null
    pixels=$((points * 2))
    sips -z "$pixels" "$pixels" "$source_icon" --out "$iconset/icon_${points}x${points}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$PWD/Sources/QuotaBar/Resources/QuotaBar.icns"
