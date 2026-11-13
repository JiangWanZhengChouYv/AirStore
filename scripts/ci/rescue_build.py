#!/usr/bin/env python3
"""Re-dispatch a develop build that the hosted macOS pool dropped.

Hosted macOS runners are shared, and a job that cannot be acquired within about fifteen minutes is
cancelled by GitHub without a single step having run. The commit then has no package and no feed
entry, and nothing notices: the push already happened and its workflow will not run again.

This looks for exactly that shape -- a run at the current tip whose build job was cancelled before its
first step -- and asks for the build again. Every other failure is left alone on purpose: a red build
is a code problem, and re-dispatching it every twenty minutes would spend the same scarce runners on
it forever.
"""

import datetime
import json
import os
import subprocess
import sys

REPO = os.environ.get("GITHUB_REPOSITORY", "")
WORKFLOW = "develop.yml"
BUILD_JOB = "Build AirStore"
BUNDLE_SUFFIX = ".AirStore"

# A job that dies in the queue takes about fifteen minutes to do so; waiting twenty minutes between
# attempts therefore looks at a settled result instead of racing the previous rescue.
SETTLE_MINUTES = 20


def gh(*args: str) -> str:
    return subprocess.check_output(["gh", *args], text=True)


def gh_json(*args: str):
    return json.loads(gh(*args))


def built_version() -> str:
    """The version the develop channel currently points at."""
    import base64

    encoded = gh("api", f"repos/{REPO}/contents/source/airstore-source.json?ref=develop-source", "--jq", ".content")
    feed = json.loads(base64.b64decode(encoded))

    for app in feed.get("apps", []):
        if not app.get("bundleIdentifier", "").endswith(BUNDLE_SUFFIX):
            continue
        for channel in app.get("releaseChannels", []):
            if channel.get("track") == "develop":
                return channel["releases"][0]["version"]
    return ""


def main() -> int:
    tip = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    short = tip[:7]

    version = built_version()
    if version.endswith(f"-{short}"):
        print(f"{short} is already published as {version}; nothing to rescue")
        return 0

    runs = gh_json("run", "list", "--workflow", WORKFLOW, "--limit", "20",
                   "--json", "databaseId,headSha,status,conclusion,createdAt,event")
    mine = [run for run in runs if run["headSha"] == tip]
    if not mine:
        # A paths-ignored push (docs, workflows) deliberately produces no run. There is nothing to
        # rebuild and nothing to rescue.
        print(f"no run at all for {short}; treating it as a push that needed no build")
        return 0

    latest = max(mine, key=lambda run: run["databaseId"])
    if latest["status"] in ("queued", "in_progress"):
        print(f"run {latest['databaseId']} for {short} is still {latest['status']}; waiting")
        return 0

    created = datetime.datetime.fromisoformat(latest["createdAt"].replace("Z", "+00:00"))
    age = (datetime.datetime.now(datetime.timezone.utc) - created).total_seconds() / 60
    if age < SETTLE_MINUTES:
        print(f"run {latest['databaseId']} finished {age:.0f} min ago; letting it settle")
        return 0

    jobs = gh_json("api", f"repos/{REPO}/actions/runs/{latest['databaseId']}/jobs")
    job = next((item for item in jobs.get("jobs", []) if item["name"] == BUILD_JOB), None)
    if job is None:
        print(f"run {latest['databaseId']} has no {BUILD_JOB} job; leaving it alone")
        return 0

    starved = job.get("conclusion") == "cancelled" and not job.get("steps")
    if not starved:
        print(f"{BUILD_JOB} concluded '{job.get('conclusion')}' with {len(job.get('steps') or [])} step(s); that is not a queue problem")
        return 0

    print(f"{short}: {BUILD_JOB} was cancelled before its first step -- asking for the build again")
    gh("workflow", "run", WORKFLOW, "--ref", "develop", "-f", "app_only=false")
    return 0


if __name__ == "__main__":
    sys.exit(main())
