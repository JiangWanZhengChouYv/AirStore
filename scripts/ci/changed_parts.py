#!/usr/bin/env python3
"""Which optional builds a push to develop actually needs.

Two macOS runners and one Windows runner are spent on packages that rarely move: AirBox follows the
container and the Xcode project, the Helper follows its own Tauri tree. The workflow hands this
script the list of paths the push touched (git diff against the previous tip) and gets two flags
back, so a change to the app alone no longer pays for three other compiles.

Ambiguity rebuilds everything. A build that should have run but did not leaves a stale package on
the release, which is worse than one unnecessary compile -- so an empty or missing file list means
"build it all".
"""

import argparse
import sys
from pathlib import Path

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


def read_paths(path):
    """The changed paths, or None when the file is missing or empty."""
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError:
        return None
    names = {line.strip() for line in text.splitlines() if line.strip()}
    return names or None


def touches(files, prefixes):
    return any(path.startswith(prefix) for path in files for prefix in prefixes)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--files", required=True, help="newline-separated paths the push touched")
    args = parser.parse_args()

    files = read_paths(args.files)
    if files is None:
        print("changed_parts: no file list, rebuilding everything", file=sys.stderr)
    else:
        preview = " ".join(sorted(files)) if len(files) <= 30 else "%d files" % len(files)
        print("changed_parts: %s" % preview, file=sys.stderr)

    for name, prefixes in (("airbox", AIRBOX_PATHS), ("helper", HELPER_PATHS)):
        print("%s=%s" % (name, "true" if files is None or touches(files, prefixes) else "false"))


if __name__ == "__main__":
    main()
