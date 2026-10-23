#!/usr/bin/env python3
"""Optional status-line exporter. Does not install itself or modify Claude settings.

Keeps only rate limits, a sample timestamp, and the active organization identifier.
Never persists raw stdin (which may contain unrelated session metadata).
"""
import json
import math
import os
from pathlib import Path
import sys
import tempfile
import time


def numeric(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def main():
    payload = json.load(sys.stdin)
    limits = payload.get("rate_limits") or {}
    selected = {}
    for key in ("five_hour", "seven_day"):
        row = limits.get(key)
        if not isinstance(row, dict):
            continue
        used = row.get("used_percentage")
        if not numeric(used) or not 0 <= used <= 100:
            continue
        selected[key] = {"used_percentage": used}
        reset = row.get("resets_at")
        if numeric(reset) and reset > 0:
            selected[key]["resets_at"] = reset
    if not selected:
        return
    home = Path.home()
    config_path = Path(os.environ.get("QUOTABAR_CLAUDE_ACCOUNT_FILE", home / ".claude.json"))
    account = json.loads(config_path.read_text()).get("oauthAccount") or {}
    org = account.get("organizationUuid")
    if not isinstance(org, str) or not org:
        return
    target = Path(os.environ.get("QUOTABAR_CLAUDE_CACHE", home / "Library/Application Support/QuotaBar/claude-statusline.json"))
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    sanitized = {"organizationID": org, "capturedAt": int(time.time() * 1000), "rate_limits": selected}
    fd, temporary = tempfile.mkstemp(prefix=".claude-usage-", dir=target.parent)
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(sanitized, handle, allow_nan=False)
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    pieces = [f"{label}: {100 - selected[key]['used_percentage']:g}% left" for key, label in
              (("five_hour", "5h"), ("seven_day", "week")) if key in selected]
    print(" · ".join(pieces))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TypeError, AttributeError):
        # Status-line output must never leak raw input or credentials on failure.
        pass
