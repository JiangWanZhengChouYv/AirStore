#!/bin/bash
# Watch a GitHub Actions run with a progress bar instead of silence.
#
#   scripts/ci-watch.sh                 # newest run on the current branch
#   scripts/ci-watch.sh 39244937774     # a specific run
#   ESTIMATE=600 scripts/ci-watch.sh    # override the time estimate in seconds
#
# The bar is time based, because one xcodebuild step is most of the run: counting steps would
# sit at 60% for nine minutes and then jump. Elapsed time is compared against the last run of the
# same workflow, so the estimate follows the repo's real history.

set -uo pipefail

RUN="${1:-}"
REPO="JiangWanZhengChouYv/AirStore"
BAR_WIDTH=24
INTERVAL=15

if [ -z "$RUN" ]; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo develop)
  RUN=$(gh api "repos/$REPO/actions/runs?branch=$BRANCH&per_page=1" --jq '.workflow_runs[0].id')
fi

if [ -z "$RUN" ] || [ "$RUN" = "null" ]; then
  echo "no run found" >&2
  exit 1
fi

json() { gh api "repos/$REPO/actions/runs/$RUN" --jq "$1" 2>/dev/null; }

started=$(json '.run_started_at')
workflow=$(json '.name')
title=$(json '.display_title')
status=$(json '.status')

# Estimate from the last completed run of the same workflow, else nine minutes.
estimate=${ESTIMATE:-}
if [ -z "$estimate" ]; then
  estimate=$(gh api "repos/$REPO/actions/workflows/$workflow/runs?status=completed&per_page=6" \
    --argjson self "$RUN" \
    '[.workflow_runs[] | select(.id != $self)
      | ((.updated_at | fromdate) - (.run_started_at | fromdate))]
     | if length > 0 then (add / length | floor) else 540 end' 2>/dev/null || echo 540)
fi
case "$estimate" in (''|*[!0-9]*) estimate=540;; esac

now_epoch() { date +%s; }
# BSD date parses a bare timestamp in local time, which for this machine is UTC+8: without -u the
# elapsed figure starts 8 hours high and the bar sits pinned at 99%.
start_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$started" +%s 2>/dev/null || now_epoch)

echo "run $RUN · $workflow · $title"
echo "estimated ${estimate}s from the last completed run"
echo

while true; do
  status=$(json '.status')
  conclusion=$(json '.conclusion // ""')

  # Recompute the step line each pass; the list is short and gh is cheap here.
  steps=$(gh api "repos/$REPO/actions/runs/$RUN/jobs" \
    --jq '.jobs[].steps[] | "\(.status)\t\(.conclusion // "-")\t\(.name)"' 2>/dev/null)
  total=$(printf '%s\n' "$steps" | grep -c .)
  done_steps=$(printf '%s\n' "$steps" | grep -cE '^completed')
  current=$(printf '%s\n' "$steps" | awk -F'\t' '$1=="in_progress"{print $3; exit}')
  [ -z "$current" ] && current=$(printf '%s\n' "$steps" | awk -F'\t' '$1!="completed"{print $3; exit}')

  elapsed=$(( $(now_epoch) - start_epoch ))
  [ "$elapsed" -lt 0 ] && elapsed=0
  if [ "$total" -eq 0 ]; then
    # No steps at all means no runner has taken the job; letting the bar creep would be a lie.
    pct=0
    label="排队中（等 runner）"
  else
    pct=$(( elapsed * 100 / estimate ))
    label="${current:-等待中}"
  fi
  [ "$pct" -gt 99 ] && pct=99
  if [ "$status" = "completed" ]; then pct=100; fi
  filled=$(( pct * BAR_WIDTH / 100 ))
  bar=""
  i=0
  while [ $i -lt $BAR_WIDTH ]; do
    if [ $i -lt $filled ]; then bar="${bar}█"; else bar="${bar}░"; fi
    i=$((i + 1))
  done

  printf '\r[%s] %3d%%  %d/%d 步  %ds  · %s' "$bar" "$pct" "$done_steps" "$total" "$elapsed" "$label"

  if [ "$status" = "completed" ]; then
    printf '\n'
    break
  fi
  sleep "$INTERVAL"
done

echo
echo "结论: ${conclusion:-unknown}"
echo
printf '%s\n' "$steps" | awk -F'\t' '$2!="success" && $2!="" {printf "  %-9s %s\n", $2, $3}'
echo
echo "产物:"
gh api "repos/$REPO/actions/runs/$RUN/artifacts" --jq '.artifacts[].name' 2>/dev/null | sed 's/^/  /'

if [ "$conclusion" = "failure" ]; then
  echo
  echo "报错:"
  gh run view "$RUN" --log-failed 2>/dev/null \
    | grep -iE "error:|fatal|The following build commands failed" \
    | sed -E 's/^[^\t]*\t[^\t]*\t[0-9TZ:.-]+Z? ?//' | sort -u | head -12
fi
