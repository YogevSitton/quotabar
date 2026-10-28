#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
# Version and build come only from release-version.json and public history.
# QUOTABAR_RELEASE_BUILD=1 (trusted release workflow only) fails closed on any
# identity problem; otherwise this is a source build that cannot self-update.
identity="$(/bin/zsh scripts/build-identity.sh)"
identity_value() {
  local line
  for line in "${(@f)identity}"; do
    [[ "$line" == "$1="* ]] && { print -r -- "${line#*=}"; return; }
  done
  print -u2 "build: identity has no $1"; exit 1
}
display_version="$(identity_value displayVersion)"
build_number="$(identity_value build)"
update_commit="$(identity_value commit)"
update_mode="$(identity_value mode)"
update_public_key="$(identity_value publicKey)"
build_root="${QUOTABAR_BUILD_PATH:-$PWD/.build}"
export CLANG_MODULE_CACHE_PATH="$build_root/ModuleCache"
swift build -c release --disable-sandbox --scratch-path "$build_root"
bin_path="$(swift build -c release --disable-sandbox --scratch-path "$build_root" --show-bin-path)"
bundle="$PWD/dist/QuotaBar.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
# Remove the obsolete, app-generated browser reader from earlier local builds.
rm -rf "$bundle/Contents/Resources/QuotaBar_QuotaBar.bundle"
cp "$bin_path/QuotaBar" "$bundle/Contents/MacOS/QuotaBar"
cp Sources/QuotaBar/Resources/*.icns Sources/QuotaBar/Resources/*.pdf "$bundle/Contents/Resources/"
cp LICENSE "$bundle/Contents/Resources/QuotaBar-LICENSE.txt"
cp Assets/ICON.md "$bundle/Contents/Resources/Provider-Artwork-NOTICE.md"
cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>QuotaBar</string>
<key>CFBundleDisplayName</key><string>QuotaBar</string>
<key>CFBundleIdentifier</key><string>com.yogev.quotabar</string>
<key>CFBundleExecutable</key><string>QuotaBar</string>
<key>CFBundleIconFile</key><string>QuotaBar.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$display_version</string>
<key>CFBundleVersion</key><string>$build_number</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>QuotaBarUpdateMode</key><string>$update_mode</string>
<key>QuotaBarUpdatePublicKey</key><string>$update_public_key</string>
<key>QuotaBarUpdateCommit</key><string>$update_commit</string>
</dict></plist>
PLIST
# The one-shot update helper, with the same identity as the app it installs.
helper="$bundle/Contents/Helpers/QuotaUpdater.app"
rm -rf "$helper"
mkdir -p "$helper/Contents/MacOS"
cp "$bin_path/QuotaUpdater" "$helper/Contents/MacOS/QuotaUpdater"
cat > "$helper/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>QuotaUpdater</string>
<key>CFBundleIdentifier</key><string>com.yogev.quotabar.updater</string>
<key>CFBundleExecutable</key><string>QuotaUpdater</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$display_version</string>
<key>CFBundleVersion</key><string>$build_number</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSBackgroundOnly</key><true/>
<key>QuotaBarUpdateMode</key><string>$update_mode</string>
<key>QuotaBarUpdatePublicKey</key><string>$update_public_key</string>
<key>QuotaBarUpdateCommit</key><string>$update_commit</string>
</dict></plist>
PLIST
# Sign inside out: the helper first, then the app that seals it. A configured
# certificate can preserve Keychain trust across updates. The default remains
# an ad-hoc local build; never change Keychain ACLs to bypass it.
codesign --force --sign "${QUOTABAR_SIGN_IDENTITY:--}" "$helper"
codesign --force --sign "${QUOTABAR_SIGN_IDENTITY:--}" "$bundle"
touch "$bundle"
printf 'Built %s (%s build %s, %s mode)\n' "$bundle" "$display_version" "$build_number" "$update_mode"
