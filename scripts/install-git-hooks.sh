#!/bin/sh
# Installs the public-record git hooks for this clone and every worktree of it.
# The hooks and the checkers they run are copied into the clone's git
# directory, and core.hooksPath points there, so the hooks also run in
# checkouts of branches that predate them and never run code from whatever
# branch is checked out. Run it again after pulling changes to scripts/git-hooks
# or to the checkers they call.
set -eu
top=$(git rev-parse --show-toplevel)
common=$(cd "$top" && cd "$(git rev-parse --git-common-dir)" && pwd)
dest=$common/quotabar-hooks
current=$(git config --get core.hooksPath || true)
case "$current" in
  '' | scripts/git-hooks | "$dest/git-hooks") ;;
  *)
    echo "core.hooksPath is already $current; unset it first (git config --unset core.hooksPath) to use these hooks." >&2
    exit 1
    ;;
esac
rm -rf "$dest.new"
mkdir -p "$dest.new/git-hooks"
cp "$top"/scripts/git-hooks/* "$dest.new/git-hooks/"
cp "$top/scripts/audit-public-tree.py" "$top/scripts/check-public-text.py" "$top/scripts/check-commit-identity.py" "$dest.new/"
chmod 755 "$dest.new"/git-hooks/*
rm -rf "$dest"
mv "$dest.new" "$dest"
git config core.hooksPath "$dest/git-hooks"
echo "Installed the public-record hooks for every worktree of this clone."
for hook in "$common"/hooks/*; do
  case "$hook" in
    *.sample) ;;
    *) [ -f "$hook" ] && echo "Note: $hook is ignored while core.hooksPath is set." ;;
  esac
done
if [ -f "$common/quotabar-private-terms.txt" ]; then
  echo "Private terms are read from $common/quotabar-private-terms.txt."
else
  echo "No private terms yet; a maintainer adds one with: python3 scripts/check-public-text.py --add-term"
fi
