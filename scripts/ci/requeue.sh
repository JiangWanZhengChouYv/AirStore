#!/usr/bin/env bash
# Re-dispatch a develop build that has been sitting in the runner queue for too long.
#
# A queued run holds no runner and has done no work, so asking again costs the queue position and
# nothing else. Two guards matter more than the timeout: never cancel a run that has actually started,
# and never re-dispatch while another build of the same workflow is running -- that running build is
# what the queue is waiting behind, and adding a second one only makes both wait longer.
#
#   scripts/ci/requeue.sh                      # newest develop run, 10 min timeout, 2 requeues
#   scripts/ci/requeue.sh 41076339963 --timeout 600 --max 2
#   scripts/ci/requeue.sh --dry-run            # say what it would do, change nothing
#   scripts/ci/requeue.sh --self-test          # exercise the decision table, no network
set -uo pipefail

REPO="${REPO:-$(git config --get remote.origin.url 2>/dev/null | sed -E 's#.*github\.com[:/]##; s#\.git$##')}"
WORKFLOW="${WORKFLOW:-develop.yml}"
BRANCH="${BRANCH:-develop}"
RUN_ID=""
TIMEOUT=600
MAX=2
DRY=0
POLL=30

while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --max) MAX="$2"; shift 2 ;;
    --poll) POLL="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --self-test) SELF_TEST=1; shift ;;
    --help|-h) sed -n '2,13p' "$0"; exit 0 ;;
    *) RUN_ID="$1"; shift ;;
  esac
done

say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }

# Seconds a run has spent queued, from its creation time. -u on purpose: without it BSD date parses
# the UTC timestamp as local time and reports an offset of exactly the timezone.
waited_seconds() {
  local created="$1"
  local created_epoch now
  created_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$created" +%s 2>/dev/null) || { echo 0; return; }
  now=$(date -u +%s)
  echo $((now - created_epoch))
}

# The whole decision, so it can be exercised without GitHub: prints start | wait | requeue | give-up.
decide() {
  local status="$1" waited="$2" timeout="$3" attempts="$4" max="$5" others_running="$6"
  case "$status" in
    in_progress|completed) echo start; return ;;
  esac
  if [ "$others_running" -gt 0 ]; then echo wait; return; fi
  if [ "$waited" -lt "$timeout" ]; then echo wait; return; fi
  if [ "$attempts" -ge "$max" ]; then echo give-up; return; fi
  echo requeue
}

self_test() {
  local failures=0
  check() {
    local got; got=$(decide "$1" "$2" "$3" "$4" "$5" "$6")
    if [ "$got" = "$7" ]; then printf 'ok   %s/%ss/attempt %s/others %s -> %s\n' "$1" "$2" "$4" "$6" "$got"
    else printf 'FAIL %s/%ss/attempt %s/others %s -> %s (want %s)\n' "$1" "$2" "$4" "$6" "$got" "$7"; failures=$((failures+1)); fi
  }
  check queued  600 600 0 2 0 requeue
  check queued   60 600 0 2 0 wait
  check queued 1200 600 2 2 0 give-up
  check queued 1200 600 0 2 1 wait
  check in_progress 9999 600 0 2 0 start
  check completed   0 600 0 2 0 start
  [ "$failures" -eq 0 ] && echo "self-test: all cases pass" || echo "self-test: $failures failed"
  [ "$failures" -eq 0 ]
}

if [ "${SELF_TEST:-0}" = "1" ]; then self_test; exit $?; fi

if [ -z "$REPO" ]; then echo "no github remote here; set REPO=owner/name" >&2; exit 1; fi
if [ -z "$RUN_ID" ]; then
  RUN_ID=$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --branch "$BRANCH" --limit 1 --json databaseId --jq '.[0].databaseId')
  [ -n "$RUN_ID" ] || { echo "no run of $WORKFLOW on $BRANCH" >&2; exit 1; }
fi

attempts=0
while :; do
  info=$(gh api "repos/$REPO/actions/runs/$RUN_ID" --jq '"\(.status) \(.created_at)"' 2>/dev/null) \
    || { echo "cannot read run $RUN_ID" >&2; exit 1; }
  status=${info%% *}
  created=${info#* }
  waited=$(waited_seconds "$created")

  others=$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --branch "$BRANCH" --limit 20 \
             --json databaseId,status --jq "[.[] | select(.databaseId != $RUN_ID and .status == \"in_progress\")] | length" 2>/dev/null || echo 0)

  action=$(decide "$status" "$waited" "$TIMEOUT" "$attempts" "$MAX" "$others")
  case "$action" in
    start)
      say "run $RUN_ID is $status after $((waited / 60)) min queued; nothing to do"
      exit 0 ;;
    wait)
      if [ "$others" -gt 0 ]; then
        say "run $RUN_ID queued $((waited / 60)) min, but another build is running -- that is the queue, waiting"
      else
        say "run $RUN_ID queued $((waited / 60)) min of ${TIMEOUT}s, waiting"
      fi
      sleep "$POLL" ;;
    give-up)
      say "run $RUN_ID still queued after $attempts requeue(s); giving up -- GitHub's queue is the problem"
      exit 1 ;;
    requeue)
      if [ "$DRY" = "1" ]; then
        say "would cancel $RUN_ID (queued $((waited / 60)) min) and ask for a new $WORKFLOW run on $BRANCH"
        exit 0
      fi
      say "run $RUN_ID queued $((waited / 60)) min; cancelling and asking again"
      gh run cancel "$RUN_ID" --repo "$REPO" >/dev/null 2>&1 || true
      # The cancel is asynchronous; give it a moment so the new run does not queue behind a corpse.
      sleep 10
      gh workflow run "$WORKFLOW" --ref "$BRANCH" --repo "$REPO" >/dev/null || { echo "dispatch failed" >&2; exit 1; }

      new_id=""
      for _ in $(seq 1 12); do
        sleep 5
        new_id=$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --branch "$BRANCH" --limit 1 \
                   --json databaseId --jq '.[0].databaseId' 2>/dev/null)
        [ -n "$new_id" ] && [ "$new_id" != "$RUN_ID" ] && break
        new_id=""
      done
      [ -n "$new_id" ] || { echo "dispatched, but no new run appeared" >&2; exit 1; }
      say "new run $new_id replaces $RUN_ID"
      RUN_ID="$new_id"
      attempts=$((attempts + 1)) ;;
  esac
done
