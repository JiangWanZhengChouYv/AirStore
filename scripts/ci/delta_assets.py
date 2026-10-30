#!/usr/bin/env python3
"""Which packages a build cuts deltas from, and what those patches are called.

One rule, so CI and the phone cannot drift apart: a patch is named after the package it produces and
the base it starts from --

    <target package name minus .ipa>-<first 12 hex of the base's ASBU SHA-256>.patch

A phone knows the hash of the base sitting in its own cache, so it constructs the name of the one
patch it can use and asks for exactly that asset. A base outside CI's retention window simply 404s,
and the caller downloads the whole package instead -- the same fallback that already covers every
other delta doubt. This is what removes the one-step-at-a-time restriction: a build that is three
behind still gets a delta, as long as the package it came from is still on the release.

`bases` and `stale` take a release's JSON (the REST shape from
`gh api repos/<repo>/releases/tags/<tag>`) and look at nothing but .name and .id. The id matters:
`gh release view --json assets` returns GraphQL node strings, and ranking those is alphabetical rather
than by upload order, which once cut a patch from a package two builds behind the live one.

    make_patch.py-style calls, here:
    delta_assets.py bases --release-json build/release.json --limit 4
    delta_assets.py name  --package 0.8.3-develop-...64-abcd1234.ipa --base-sha <64 hex>
    delta_assets.py stale --release-json build/release.json --keep 5
"""
import argparse
import json
import sys

BASE_TAG_LENGTH = 12      # hex digits of the base hash that go into a patch's name
PACKAGE_SUFFIX = ".ipa"
PATCH_SUFFIX = ".patch"


def load_release(path):
    """Asset list of a release, tolerant of the release not existing yet."""
    if path == "-":
        raw = sys.stdin.read()
    else:
        with open(path) as handle:
            raw = handle.read()
    if not raw.strip():
        return []
    document = json.loads(raw)
    return document.get("assets") or []


def packages(assets):
    """The .ipa assets, newest upload first."""
    found = [asset for asset in assets if (asset.get("name") or "").endswith(PACKAGE_SUFFIX)]
    return sorted(found, key=lambda asset: asset.get("id") or 0, reverse=True)


def base_names(assets, limit):
    """Names of the packages a new build should cut deltas from."""
    return [asset["name"] for asset in packages(assets)[:limit]]


def patch_name(package_name, base_sha):
    """The asset name a patch from `base_sha` to `package_name` is published under."""
    stem = package_name[: -len(PACKAGE_SUFFIX)] if package_name.endswith(PACKAGE_SUFFIX) else package_name
    return "{}-{}{}".format(stem, str(base_sha)[:BASE_TAG_LENGTH], PATCH_SUFFIX)


def stem_of(name):
    """A package or patch name with its extension removed."""
    for suffix in (PACKAGE_SUFFIX, PATCH_SUFFIX):
        if name.endswith(suffix):
            return name[: -len(suffix)]
    return name


def stale_names(assets, keep):
    """Every asset belonging to a build older than the `keep` newest packages.

    Ownership is a prefix test against the packages that stay, so a build's `.ipa` and every patch
    cut to or from it go together. A patch carries the base tag after its own version's name and a
    package never does, so matching the stem plus a dash is enough -- no hash parsing, and the older
    fixed-name patches still follow the build they were published with.
    """
    kept = [stem_of(asset["name"]) for asset in packages(assets)[:keep]]

    def stays(name):
        stem = stem_of(name)
        return any(stem == owner or stem.startswith(owner + "-") for owner in kept)

    return [asset["name"] for asset in assets if not stays(asset.get("name") or "")]


def kept_names(assets, keep):
    """The mirror of `stale_names`: what a release should hold after pruning.

    Listed separately because the Pages branch is a copy of the release and has to end up holding the
    same set of files, so it is asked here rather than working out its own idea of a build.
    """
    stale = set(stale_names(assets, keep))
    return [asset["name"] for asset in assets if asset.get("name") not in stale]


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)

    bases = commands.add_parser("bases", help="packages to cut deltas from, newest first")
    bases.add_argument("--release-json", required=True)
    bases.add_argument("--limit", type=int, default=4)

    name = commands.add_parser("name", help="asset name of one patch")
    name.add_argument("--package", required=True)
    name.add_argument("--base-sha", required=True)

    stale = commands.add_parser("stale", help="assets of builds past the retention window")
    stale.add_argument("--release-json", required=True)
    stale.add_argument("--keep", type=int, default=5)

    stay = commands.add_parser("kept", help="assets that belong to the builds staying")
    stay.add_argument("--release-json", required=True)
    stay.add_argument("--keep", type=int, default=5)

    arguments = parser.parse_args()
    if arguments.command == "bases":
        print("\n".join(base_names(load_release(arguments.release_json), arguments.limit)))
    elif arguments.command == "stale":
        print("\n".join(stale_names(load_release(arguments.release_json), arguments.keep)))
    elif arguments.command == "kept":
        print("\n".join(kept_names(load_release(arguments.release_json), arguments.keep)))
    else:
        print(patch_name(arguments.package, arguments.base_sha))


if __name__ == "__main__":
    main()
