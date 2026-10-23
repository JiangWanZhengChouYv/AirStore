#!/usr/bin/env python3
"""Fold a develop build into the source JSON AirStore subscribes to.

The checked-in source/airstore-source.json stays the human-authored truth for the stable track:
this script reads it, replaces only the develop release of the store app's own entry, and writes
the result for the workflow to commit onto the branch the app actually fetches from. That way a
per-commit build cannot overwrite a hand-written release note or the stable download URL.
"""

import argparse
import datetime
import hashlib
import json
from pathlib import Path


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, help="checked-in source JSON to read")
    parser.add_argument("--ipa", required=True, help="the freshly built ipa")
    parser.add_argument("--bundle-id", required=True, help="which app entry in the source is AirStore itself")
    parser.add_argument("--version", required=True, help="version string baked into the ipa")
    parser.add_argument("--download-url", required=True, help="where the app will fetch this ipa from")
    parser.add_argument("--track", default="develop", help="release channel to write")
    parser.add_argument("--description", default="", help="what the update card says")
    parser.add_argument("--out", required=True, help="where to write the merged JSON")
    args = parser.parse_args()

    source = json.loads(Path(args.source).read_text(encoding="utf-8"))
    ipa = Path(args.ipa)
    if not ipa.is_file():
        raise SystemExit(f"Missing ipa: {ipa}")

    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    release = {
        "version": args.version,
        "date": now,
        "downloadURL": args.download_url,
        "size": ipa.stat().st_size,
        "sha256": sha256_of(ipa),
    }
    if args.description:
        release["localizedDescription"] = args.description

    for app in source.get("apps", []):
        if app.get("bundleIdentifier") != args.bundle_id:
            continue

        # The card shown in Browse is the newest release, so it has to carry the develop build too,
        # or the app would list an update it cannot describe.
        app.update(release)
        if args.description:
            app["localizedDescription"] = args.description

        app["versions"] = [release] + [
            older for older in app.get("versions", []) if older.get("version") != release["version"]
        ]

        channels = app.get("releaseChannels", [])
        channels = [c for c in channels if c.get("track") != args.track]
        channels.insert(0, {"track": args.track, "releases": [release]})
        app["releaseChannels"] = channels
        break
    else:
        raise SystemExit(f"No app with bundle id {args.bundle_id} in {args.source}")

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(source, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Wrote {out} with {args.track} release {args.version} ({release['size']} bytes).")


if __name__ == "__main__":
    main()
