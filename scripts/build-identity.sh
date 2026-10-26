#!/bin/zsh
# Prints the app's build identity as KEY=VALUE lines from release-version.json
# and public first-parent history. See docs/UPDATES.md.
#
# The build number is anchorBuild plus the first-parent commits since
# anchorCommit, the public commit that shipped as build 28 (v0.1.0). Squash-only
# main with linear history keeps it increasing.
#
# Source mode (default) never fails: without the anchor or full history it uses
# build 0. Release mode (QUOTABAR_RELEASE_BUILD=1, set only by the trusted
# release workflow) fails closed on any identity problem.
set -euo pipefail
cd "${0:A:h}/.."
config="$PWD/release-version.json"
release_mode="${QUOTABAR_RELEASE_BUILD:-0}"

fail() {
  print -u2 "build identity: $1"
  exit 1
}

read_config() {
  /usr/bin/plutil -extract "$1" raw -o - "$config" 2>/dev/null || fail "release-version.json has no valid $1"
}

[[ -f "$config" ]] || fail "release-version.json is missing"
[[ "$(read_config schema)" == 1 ]] || fail "unsupported release-version.json schema"
display_version="$(read_config displayVersion)"
anchor_commit="$(read_config anchorCommit)"
anchor_build="$(read_config anchorBuild)"
public_key="$(/usr/bin/plutil -extract publicKey raw -o - "$config" 2>/dev/null || true)"

[[ "$display_version" =~ '^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$' ]] || fail "displayVersion must be numeric major.minor.patch"
[[ "$anchor_commit" =~ '^[0-9a-f]{40}$' ]] || fail "anchorCommit must be a full commit SHA"
[[ "$anchor_build" =~ '^[0-9]{1,9}$' ]] || fail "anchorBuild must be a number"
if [[ -n "$public_key" && ! "$public_key" =~ '^[A-Za-z0-9+/]{43}=$' ]]; then
  fail "publicKey must be an empty string or a base64 Ed25519 public key"
fi

build_number=""
commit=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [[ "$(git rev-parse --is-shallow-repository)" == false ]] &&
     git cat-file -e "$anchor_commit^{commit}" 2>/dev/null; then
    first_parent=("${(@f)$(git rev-list --first-parent HEAD)}")
    if (( ${first_parent[(Ie)$anchor_commit]} )); then
      build_number=$(( anchor_build + $(git rev-list --first-parent --count "$anchor_commit..HEAD") ))
    fi
  fi
  commit="$(git rev-parse HEAD)"
fi

if [[ "$release_mode" == 1 ]]; then
  [[ -n "$build_number" ]] || fail "release builds need full history containing the anchor commit on the first-parent line"
  (( build_number > 28 )) || fail "release builds must be newer than build 28"
  [[ -n "$public_key" ]] || fail "release builds need the committed update public key"
  [[ "$commit" =~ '^[0-9a-f]{40}$' ]] || fail "release builds need a Git commit"
  [[ -z "$(git status --porcelain --untracked-files=normal)" ]] || fail "release builds need a clean worktree"
  mode=release
else
  # Source builds are never distributed and cannot install updates.
  build_number="${build_number:-0}"
  commit=""
  mode=source
fi

print -r -- "displayVersion=$display_version"
print -r -- "build=$build_number"
print -r -- "commit=$commit"
print -r -- "mode=$mode"
print -r -- "publicKey=$public_key"
