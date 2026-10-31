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

    # A second app published next to the store (AirBox). It has no stable entry in the checked-in
    # source, so the entry is created here and only ever carries the track this build publishes --
    # listing it as stable would advertise a package no stable release actually ships.
    parser.add_argument("--companion-bundle-id", default="", help="second app to carry in the same source")
    parser.add_argument("--companion-ipa", default="", help="the freshly built companion package")
    parser.add_argument("--companion-download-url", default="", help="where the companion will be fetched from")
    parser.add_argument("--companion-name", default="AirBox")
    parser.add_argument("--companion-developer", default="AirStore团队")
    parser.add_argument("--companion-subtitle", default="Run apps inside AirBox without using App IDs")
    parser.add_argument("--companion-tint", default="8B5CF6")
    parser.add_argument("--companion-icon-url", default="https://cdn.jsdelivr.net/gh/JiangWanZhengChouYv/AirStore@develop/AirBox/Assets.xcassets/AppIcon.appiconset/1024.png")
    parser.add_argument("--companion-description", default="")
    args = parser.parse_args()

    source = json.loads(Path(args.source).read_text(encoding="utf-8"))
    ipa = Path(args.ipa)
    if not ipa.is_file():
        raise SystemExit(f"Missing ipa: {ipa}")

    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    def make_release(path: Path, download_url: str, description: str) -> dict:
        release = {
            "version": args.version,
            "date": now,
            "downloadURL": download_url,
            "size": path.stat().st_size,
            "sha256": sha256_of(path),
        }
        if description:
            release["localizedDescription"] = description
        return release

    release = make_release(ipa, args.download_url, args.description)

    for app in source.get("apps", []):
        if app.get("bundleIdentifier") != args.bundle_id:
            continue

        # Only the channel is touched. The app-level version/description/downloadURL stay as the
        # human wrote them for the stable track: overwriting them with the develop build made the
        # store page contradict itself, with a develop description on top and "What's New: 0.8.0"
        # underneath as soon as beta updates were switched off.
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

    if args.companion_bundle_id:
        companion_ipa = Path(args.companion_ipa)
        if not companion_ipa.is_file():
            raise SystemExit(f"Missing companion ipa: {companion_ipa}")

        companion_release = make_release(companion_ipa, args.companion_download_url, args.companion_description)

        apps = source.setdefault("apps", [])
        companion = next((app for app in apps if app.get("bundleIdentifier") == args.companion_bundle_id), None)
        if companion is None:
            companion = {
                "name": args.companion_name,
                "bundleIdentifier": args.companion_bundle_id,
                "developerName": args.companion_developer,
                "subtitle": args.companion_subtitle,
                "iconURL": args.companion_icon_url,
                "tintColor": args.companion_tint,
            }
            apps.append(companion)

        # The app-level fields follow the newest build, same as a version: that is what the store
        # shows on the page and what `hasUpdate` compares against.
        companion.update({
            "version": companion_release["version"],
            "date": companion_release["date"],
            "downloadURL": companion_release["downloadURL"],
            "size": companion_release["size"],
            "sha256": companion_release["sha256"],
        })
        companion["versions"] = [companion_release] + [
            older for older in companion.get("versions", []) if older.get("version") != companion_release["version"]
        ]
        channels = [c for c in companion.get("releaseChannels", []) if c.get("track") != args.track]
        channels.insert(0, {"track": args.track, "releases": [companion_release]})
        companion["releaseChannels"] = channels

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(source, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Wrote {out} with {args.track} release {args.version} ({release['size']} bytes).")


if __name__ == "__main__":
    main()
