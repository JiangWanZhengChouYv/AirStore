#!/bin/bash
# Watch every CI run in flight, one line each, instead of silence or a wall of log.
#
#   ciw                      # all queued/running CI, refresh until they are done
#   ciw --once               # one snapshot, no waiting
#   ciw --all                # also include the most recent finished runs
#   ciw 39786651476 ...      # specific run ids
#   ciw -b develop -i 5      # one branch, refresh every 5s
#   ESTIMATE=600 ciw         # override the seconds a build is expected to take
#
# Double-click scripts/ci-watch.command for the same thing in a Terminal window.
#
# The bar is time based on purpose: one xcodebuild step is most of the run, so counting steps sits
# at 60% for nine minutes and then jumps. The estimate comes from this workflow's own recent
# completed runs, so it follows the repo's real history rather than a guess. A run with no steps at
# all has not been given a runner yet -- drawing a creeping bar there would be a lie, so it shows
# 排队中 and stays at zero.

set -uo pipefail

REPO="JiangWanZhengChouYv/AirStore"
INTERVAL=15
MODE="running"          # running | ids | all
ONCE=0
BRANCH=""
RUN_IDS=()

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--once)    ONCE=1 ;;
    -a|--all)     MODE="all" ;;
    -b|--branch)  BRANCH="${2:-}"; shift ;;
    -i|--interval) INTERVAL="${2:-15}"; shift ;;
    -h|--help)    sed -n '2,17p' "$0"; exit 0 ;;
    ''|--*)       ;;
    *[!0-9]*)     echo "ignoring '$1' (not a run id)" >&2 ;;
    *)            MODE="ids"; RUN_IDS+=("$1") ;;
  esac
  shift
done

[ "$INTERVAL" -gt 0 ] 2>/dev/null || INTERVAL=15

if [ -t 1 ]; then
  C_DIM=$(tput dim); C_RED=$(tput setaf 1); C_GRN=$(tput setaf 2)
  C_YEL=$(tput setaf 3); C_CYN=$(tput setaf 6); C_OFF=$(tput sgr0)
else
  C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_OFF=""
fi

COLS=${COLUMNS:-$(tput cols 2>/dev/null || echo 100)}

# Everything before the bar is a fixed 57 cells: state(4) name(12) branch(10) sha(8) percent(4)
# steps(7) elapsed(5) plus the separators. Whatever is left gets split between the bar and the
# step name, so a row always ends on one line -- a wrapped row breaks the redraw accounting.
FIXED_CELLS=57
rest=$(( COLS - FIXED_CELLS - 3 ))
[ "$rest" -lt 16 ] && rest=16
BAR_WIDTH=$(( rest * 6 / 10 ))
[ "$BAR_WIDTH" -lt 6 ] && BAR_WIDTH=6
[ "$BAR_WIDTH" -gt 40 ] && BAR_WIDTH=40
STEP_WIDTH=$(( rest - BAR_WIDTH ))
[ "$STEP_WIDTH" -lt 8 ] && STEP_WIDTH=8

# "Nightly AirStore Build" and friends are all the same shape; the suffix carries no information
# once several workflows are on one screen, so show just the part that tells them apart.
shorten_workflow() {
  local name="$1"
  case "$name" in
    *"AirStore build") name="${name%"AirStore build"}" ;;
    *"AirStore Build") name="${name%"AirStore Build"}" ;;
    "CI build on push") name="CI" ;;
  esac
  name="${name% }"             # the suffix left a trailing space behind
  printf '%s' "${name:0:12}"   # cap it, or an unfamiliar workflow name shifts the whole column
}

now_epoch() { date +%s; }

# BSD date reads a bare timestamp as local time (UTC+8 here); without -u the elapsed figure starts
# eight hours high and every bar pins at 99%.
to_epoch() { date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || now_epoch; }

EST_CACHE="${TMPDIR:-/tmp}/ci-watch-estimates.$$"
trap 'rm -f "$EST_CACHE"' EXIT

# Seconds a finished run took, averaged over the last few of the same workflow.
estimate_for() {
  local workflow="$1" skip="$2" cached
  cached=$(awk -F'\t' -v w="$workflow" '$1==w {print $2; exit}' "$EST_CACHE" 2>/dev/null)
  if [ -n "$cached" ]; then printf '%s' "$cached"; return; fi
  local secs
  secs=$(gh api "repos/$REPO/actions/workflows/$workflow/runs?status=completed&per_page=6" \
    --argjson self "$skip" \
    '[.workflow_runs[] | select(.id != $self)
      | ((.updated_at | fromdate) - (.run_started_at | fromdate))]
     | if length > 0 then (add / length | floor) else 540 end' 2>/dev/null)
  case "$secs" in (''|*[!0-9]*) secs=540 ;; esac
  printf '%s\t%s\n' "$workflow" "$secs" >> "$EST_CACHE"
  printf '%s' "$secs"
}

list_ids() {
  if [ "$MODE" = "ids" ]; then
    printf '%s\n' "${RUN_IDS[@]}"
    return
  fi
  local q="repos/$REPO/actions/runs?per_page=30"
  [ -n "$BRANCH" ] && q="$q&branch=$BRANCH"
  if [ "$MODE" = "running" ]; then
    # The status filter takes exactly one value: `status=queued,in_progress` is accepted by the API
    # and answers with nothing at all, which reads as "no CI is running".
    gh api "$q&status=queued" --jq '.workflow_runs[].id' 2>/dev/null
    gh api "$q&status=in_progress" --jq '.workflow_runs[].id' 2>/dev/null
  else
    gh api "$q" --jq '.workflow_runs[:8][].id'
  fi
}

# One API call per run per pass; the caller keeps the fields around so the row and the loop's own
# status check do not each fetch the same run.
run_fields() {
  gh api "repos/$REPO/actions/runs/$1" --jq \
    '[.status, (.conclusion // ""), .name, .head_branch, .head_sha, .run_started_at, .updated_at, (.run_attempt // 1|tostring), .path] | join("\u001f")' \
    2>/dev/null
}

# Prints one row, with no trailing newline: the caller assembles the frame.
draw_run() {
  local id="$1" line="$2"
  local IFS=$'\037'
  # shellcheck disable=SC2086
  set -- $line
  unset IFS
  local status="$1" conclusion="$2" workflow="$3" branch="$4" sha="$5"
  local started="$6" updated="$7" attempt="$8" wf_path="$9"

  local steps done_steps total current
  steps=$(gh api "repos/$REPO/actions/runs/$id/jobs" --jq \
    '.jobs[].steps[] | "\(.status)\t\(.conclusion // "-")\t\(.name)"' 2>/dev/null)
  total=$(printf '%s\n' "$steps" | grep -c . )
  done_steps=$(printf '%s\n' "$steps" | grep -cE '^completed')
  current=$(printf '%s\n' "$steps" | awk -F'\t' '$1=="in_progress"{print $3; exit}')
  [ -z "$current" ] && current=$(printf '%s\n' "$steps" | awk -F'\t' '$1!="completed"{print $3; exit}')

  local elapsed
  if [ "$status" = "completed" ]; then
    elapsed=$(( $(to_epoch "$updated") - $(to_epoch "$started") ))
  else
    elapsed=$(( $(now_epoch) - $(to_epoch "$started") ))
  fi
  [ "$elapsed" -lt 0 ] && elapsed=0
  local mm=$(( elapsed / 60 )) ss=$(( elapsed % 60 ))

  local colour="$C_YEL" state="进行"
  if [ "$status" = "completed" ]; then
    case "$conclusion" in
      success) colour="$C_GRN"; state="通过" ;;
      cancelled) colour="$C_DIM"; state="取消" ;;
      *) colour="$C_RED"; state="失败" ;;
    esac
  elif [ "$status" = "queued" ] || [ "$status" = "pending" ]; then
    state="排队"
  fi

  local bar pct filled i
  if [ "$status" != "completed" ] && [ "$total" -eq 0 ]; then
    pct=0; bar=""; current="等 runner"
  else
    local est=${ESTIMATE:-}
    [ -z "$est" ] && est=$(estimate_for "$wf_path" "$id")
    pct=$(( elapsed * 100 / est ))
    [ "$pct" -gt 99 ] && [ "$status" != "completed" ] && pct=99
    [ "$status" = "completed" ] && pct=100
    filled=$(( pct * BAR_WIDTH / 100 ))
    bar=""; i=0
    while [ $i -lt "$BAR_WIDTH" ]; do
      if [ $i -lt "$filled" ]; then bar="${bar}█"; else bar="${bar}░"; fi
      i=$((i + 1))
    done
  fi

  # Two CJK characters per state, so the column is a fixed four cells wide without asking printf
  # to pad by display width (it counts bytes, and a Chinese character is three of them).
  local label="${current:-}"
  printf '%s%s%s %-12s %-10s %s %s%3d%%%s %2d/%-2d步 %02d:%02d ' \
    "$colour" "$state" "$C_OFF" "$(shorten_workflow "$workflow")" "${branch:0:10}" "${sha:0:8}" \
    "$colour" "$pct" "$C_OFF" "$done_steps" "$total" "$mm" "$ss"
  printf '[%s] ' "$bar"
  printf '%s%s%s' "$C_DIM" "${label:0:$STEP_WIDTH}" "$C_OFF"
  [ "$attempt" != "1" ] && printf ' %s(第%s次)%s' "$C_DIM" "$attempt" "$C_OFF"
}

report_finished() {
  local id="$1"
  local conclusion
  conclusion=$(gh api "repos/$REPO/actions/runs/$id" --jq '.conclusion // "unknown"' 2>/dev/null)
  case "$conclusion" in ''|null|neutral) conclusion="unknown" ;; esac

  echo "  run $id → $conclusion"
  local artifacts
  artifacts=$(gh api "repos/$REPO/actions/runs/$id/artifacts" --jq '.artifacts[].name' 2>/dev/null)
  if [ -n "$artifacts" ]; then
    printf '%s    产物:%s\n' "$C_DIM" "$C_OFF"
    printf '%s\n' "$artifacts" | sed 's/^/      /'
  fi
  if [ "$conclusion" = "failure" ]; then
    printf '%s    报错:%s\n' "$C_DIM" "$C_OFF"
    gh run view "$id" --log-failed 2>/dev/null \
      | grep -iE "error:|fatal|The following build commands failed" \
      | sed -E 's/^[^\t]*\t[^\t]*\t[0-9TZ:.-]+Z? ?//' | sort -u | head -8 | sed 's/^/      /'
  fi
}

live=""
reported=""
failed_any=0
first=1
LINES=0          # rows the previous frame took, so the next one can move back over them

while :; do
  ids=$(list_ids)
  if [ -z "$ids" ]; then
    if [ "$first" = 1 ]; then
      echo "没有在跑的 CI。最近几条："
      MODE=all ids=$(list_ids)
      [ -z "$ids" ] && { echo "  （一条都没有）"; exit 0; }
      MODE=running
      ONCE=1        # a history snapshot is not something to keep refreshing
    else
      printf '\n'
      echo "${C_GRN}全部结束。${C_OFF}"
      break
    fi
  fi
  first=0

  frame="${C_CYN}AirStore CI${C_OFF}  $(date '+%H:%M:%S')  ${C_DIM}(每 ${INTERVAL}s 刷新，Ctrl-C 退出)${C_OFF}"$'\n'
  finished=""
  for id in $ids; do
    fields=$(run_fields "$id")
    [ -z "$fields" ] && continue
    status=${fields%%$'\037'*}

    row=$(draw_run "$id" "$fields")
    [ -n "$row" ] && frame="${frame}${row}"$'\n'

    if [ "$status" != "completed" ]; then
      case "|$live|" in *"|$id|"*) ;; *) live="$live|$id" ;; esac
    else
      # Only summarise a run this session actually saw going -- a snapshot of the history would
      # otherwise print an artifact block for every finished run on screen.
      case "|$live|" in *"|$id|"*)
        case "|$reported|" in *"|$id|"*) ;; *) finished="$finished $id" ;; esac
      ;; esac
    fi
  done

  # Move back over the previous frame rather than clearing the screen: the summary of a run that
  # just finished stays readable above, and the scrollback does not fill up with repeated headers.
  [ "$LINES" -gt 0 ] && printf '\033[%dA' "$LINES"
  printf '%s\033[J' "$frame"
  LINES=$(printf '%s' "$frame" | wc -l | tr -d '[:space:]')

  for id in $finished; do
    reported="$reported|$id"
    concl=$(gh api "repos/$REPO/actions/runs/$id" --jq '.conclusion // ""' 2>/dev/null)
    [ "$concl" = "failure" ] && failed_any=1
    printf '\n'
    report_finished "$id"
    LINES=0          # from here the frame redraws below what we just committed to the scrollback
  done

  [ "$ONCE" = 1 ] && break
  sleep "$INTERVAL"
done

exit "$failed_any"
