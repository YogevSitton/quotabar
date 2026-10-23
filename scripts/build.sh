#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
build_root="${QUOTABAR_BUILD_PATH:-$PWD/.build}"
export CLANG_MODULE_CACHE_PATH="$build_root/ModuleCache"
./scripts/build-icon.sh
swift build -c release --disable-sandbox --scratch-path "$build_root"
bin_path="$(swift build -c release --disable-sandbox --scratch-path "$build_root" --show-bin-path)"
bundle="$PWD/dist/QuotaBar.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
# Remove the obsolete, app-generated browser reader from earlier local builds.
rm -rf "$bundle/Contents/Resources/QuotaBar_QuotaBar.bundle"
cp "$bin_path/QuotaBar" "$bundle/Contents/MacOS/QuotaBar"
cp Sources/QuotaBar/Resources/*.icns Sources/QuotaBar/Resources/*.pdf "$bundle/Contents/Resources/"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>QuotaBar</string>
<key>CFBundleDisplayName</key><string>QuotaBar</string>
<key>CFBundleIdentifier</key><string>com.yogev.quotabar</string>
<key>CFBundleExecutable</key><string>QuotaBar</string>
<key>CFBundleIconFile</key><string>QuotaBar.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.7.13</string>
<key>CFBundleVersion</key><string>25</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# A configured certificate can preserve Keychain trust across updates. The
# default remains an ad-hoc local build; never change Keychain ACLs to bypass it.
codesign --force --deep --sign "${QUOTABAR_SIGN_IDENTITY:--}" "$bundle"
touch "$bundle"
printf 'Built %s\n' "$bundle"
