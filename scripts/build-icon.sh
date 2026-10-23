#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
swift scripts/draw-app-icon.swift "$PWD"
icon_work="$(mktemp -d "${TMPDIR:-/tmp}/quotabar-icon.XXXXXX")"
trap 'rm -rf "$icon_work"' EXIT
for name in QuotaBar Codex Claude; do
    source_icon="$PWD/Assets/$name.png"
    iconset="$icon_work/$name.iconset"
    mkdir -p "$iconset"
    for points in 16 32 128 256 512; do
        sips -z "$points" "$points" "$source_icon" --out "$iconset/icon_${points}x${points}.png" >/dev/null
        pixels=$((points * 2))
        sips -z "$pixels" "$pixels" "$source_icon" --out "$iconset/icon_${points}x${points}@2x.png" >/dev/null
    done
    iconutil -c icns "$iconset" -o "$PWD/Sources/QuotaBar/Resources/$name.icns"
done
sips -z 256 256 "$PWD/Assets/QuotaBar.png" --out "$PWD/Assets/QuotaBar-preview.png" >/dev/null
