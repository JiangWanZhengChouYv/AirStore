#!/usr/bin/env python3
"""Which optional builds a push to develop actually needs.

Two macOS runners and one Windows runner are spent on packages that rarely move: AirBox follows the
container and the Xcode project, the Helper follows its own Tauri tree. A push event already carries
the complete file list, so the decision is a set of prefix tests -- no checkout, no diff, no extra
minutes.

Ambiguity rebuilds everything. A build that should have run but did not leaves a stale package on
the release, which is worse than one unnecessary compile.
"""

import json
import os
import sys

# A match under any prefix means that job has work to do.
#
# AirBox builds the AirBox target plus the LiveContainer engines, LiteHook, MultitaskSupport and
# ZSign it embeds -- all of them under Dependencies/ -- and nothing from SideStore/, which is what
# keeps a normal app-only change from recompiling it.
AIRBOX_PATHS = (
    "AirBox/",
    "Dependencies/",
    "Shared/",
    "AltStore.xcodeproj/",
    "Build.xcconfig",
    "Makefile",
    "scripts/ci/workflow.py",
)

# The Helper is a self-contained Tauri app: its sources, npm lockfile and Rust crates all live here.
HELPER_PATHS = (
    "Helper/",
)


def event_files():
    """Every path the push touched, or None when the event cannot say."""
    if os.environ.get("GITHUB_EVENT_NAME") != "push":
        return None

    try:
        with open(os.environ.get("GITHUB_EVENT_PATH", ""), encoding="utf-8") as handle:
            event = json.load(handle)
    except Exception:
        return None

    names = set()
    for commit in event.get("commits") or []:
        for key in ("added", "modified", "removed"):
            names.update(commit.get(key) or [])
    return names or None


def touches(files, prefixes):
    if files is None:
        return True
    return any(path.startswith(prefix) for path in files for prefix in prefixes)


def main():
    files = event_files()
    if files is None:
        print("changed_parts: no file list for this event, rebuilding everything", file=sys.stderr)
    else:
        preview = " ".join(sorted(files)) if len(files) <= 30 else "%d files" % len(files)
        print("changed_parts: %s" % preview, file=sys.stderr)

    for name, prefixes in (("airbox", AIRBOX_PATHS), ("helper", HELPER_PATHS)):
        print("%s=%s" % (name, "true" if touches(files, prefixes) else "false"))


if __name__ == "__main__":
    main()
