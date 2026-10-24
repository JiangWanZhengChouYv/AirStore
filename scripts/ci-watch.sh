#!/bin/bash
# A full-screen dashboard for every CI run in flight, plus the last few that finished.
#
#   ciw                      # watch, and keep watching after the queue empties
#   ciw --once               # one snapshot and exit (no alternate screen, safe to pipe)
#   ciw --all                # start with a longer history
#   ciw 39786651476 ...      # specific run ids
#   ciw -b develop -i 5      # one branch, refresh every 5s while runs are active
#   ESTIMATE=600 ciw         # override the seconds a build is expected to take
#
# Keys: r = refresh now, q = quit. When nothing is running it keeps the finished runs on screen
# and checks again every three minutes, so a push made from another window shows up on its own.
#
# The bar is time based on purpose: one xcodebuild step is most of the run, so counting steps sits
# at 60% for nine minutes and then jumps. The estimate comes from this workflow's own recent
# completed runs, so it follows the repo's real history rather than a guess. A run with no steps at
# all has not been given a runner yet -- drawing a creeping bar there would be a lie, so it shows
# 排队中 and stays at zero.

set -uo pipefail

REPO="JiangWanZhengChouYv/AirStore"
INTERVAL=15
IDLE_INTERVAL=180
MODE="running"          # running | ids
ONCE=0
BRANCH=""
RUN_IDS=()
HISTORY=5

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--once)     ONCE=1 ;;
    -a|--all)      HISTORY=10 ;;
    -b|--branch)   BRANCH="${2:-}"; shift ;;
    -i|--interval) INTERVAL="${2:-15}"; shift ;;
    -h|--help)     sed -n '2,17p' "$0"; exit 0 ;;
    ''|--*)        ;;
    *[!0-9]*)      echo "ignoring '$1' (not a run id)" >&2 ;;
    *)             MODE="ids"; RUN_IDS+=("$1") ;;
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

now_epoch() { date +%s; }

# BSD date reads a bare timestamp as local time (UTC+8 here); without -u the elapsed figure starts
# eight hours high and every bar pins at 99%.
to_epoch() { date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || now_epoch; }

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

# The status filter takes exactly one value: `status=queued,in_progress` is accepted by the API and
# answers with nothing at all, which reads as "no CI is running".
running_ids() {
  if [ "$MODE" = "ids" ]; then
    printf '%s\n' "${RUN_IDS[@]}"
    return
  fi
  local q="repos/$REPO/actions/runs?per_page=30"
  [ -n "$BRANCH" ] && q="$q&branch=$BRANCH"
  gh api "$q&status=queued" --jq '.workflow_runs[].id' 2>/dev/null
  gh api "$q&status=in_progress" --jq '.workflow_runs[].id' 2>/dev/null
}

recent_ids() {
  local q="repos/$REPO/actions/runs?per_page=$(( HISTORY + 10 ))"
  [ -n "$BRANCH" ] && q="$q&branch=$BRANCH"
  gh api "$q" --jq ".workflow_runs[:$HISTORY][].id" 2>/dev/null
}

run_fields() {
  gh api "repos/$REPO/actions/runs/$1" --jq \
    '[.status, (.conclusion // ""), .name, .head_branch, .head_sha, .run_started_at, .updated_at, (.run_attempt // 1|tostring), .path] | join("\u001f")' \
    2>/dev/null
}

# Prints one line for a run. Reads the run plus its job steps, so two API calls per run per poll.
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

  local label="${current:-}"
  printf '%s%s%s %-12s %-10s %s %s%3d%%%s %2d/%-2d步 %02d:%02d ' \
    "$colour" "$state" "$C_OFF" "$(shorten_workflow "$workflow")" "${branch:0:10}" "${sha:0:8}" \
    "$colour" "$pct" "$C_OFF" "$done_steps" "$total" "$mm" "$ss"
  printf '[%s] ' "$bar"
  printf '%s%s%s' "$C_DIM" "${label:0:$STEP_WIDTH}" "$C_OFF"
  [ "$attempt" != "1" ] && printf ' %s(第%s次)%s' "$C_DIM" "$attempt" "$C_OFF"
}

# One line per finished run, with its artifact, which is the thing people actually go looking for.
draw_finished() {
  local id="$1" line="$2"
  local IFS=$'\037'
  # shellcheck disable=SC2086
  set -- $line
  unset IFS
  local status="$1" conclusion="$2" workflow="$3" branch="$4" sha="$5"
  local started="$6" updated="$7" attempt="$8" wf_path="$9"

  local colour="$C_DIM" state="取消"
  case "$conclusion" in
    success) colour="$C_GRN"; state="通过" ;;
    failure) colour="$C_RED"; state="失败" ;;
    *)       colour="$C_DIM"; state="结束" ;;
  esac

  local elapsed=$(( $(to_epoch "$updated") - $(to_epoch "$started") ))
  [ "$elapsed" -lt 0 ] && elapsed=0
  local mm=$(( elapsed / 60 )) ss=$(( elapsed % 60 ))

  local artifacts
  artifacts=$(gh api "repos/$REPO/actions/runs/$id/artifacts" --jq '[.artifacts[].name] | join(" · ")' 2>/dev/null)

  printf '%s%s%s %-12s %-10s %s  %02d:%02d  %s%s%s' \
    "$colour" "$state" "$C_OFF" "$(shorten_workflow "$workflow")" "${branch:0:10}" "${sha:0:8}" \
    "$mm" "$ss" "$C_DIM" "${artifacts:0:$(( COLS - 60 ))}" "$C_OFF"
}

# Rebuilds FRAME from whatever is running and the tail of the history. Sets ANY_RUNNING.
build_frame() {
  FRAME="${C_CYN}AirStore CI${C_OFF}  $(date '+%H:%M:%S')  "
  ANY_RUNNING=0

  local running recent body=""
  running=$(running_ids)
  recent=$(recent_ids)

  local id fields status
  for id in $running; do
    fields=$(run_fields "$id") || continue
    [ -z "$fields" ] && continue
    body="${body}$(draw_run "$id" "$fields")"$'\n'
    ANY_RUNNING=1
  done

  if [ "$ANY_RUNNING" = 0 ]; then
    FRAME="${FRAME}${C_DIM}空闲 · 每 $(( IDLE_INTERVAL / 60 )) 分钟自检 · r 刷新 · q 退出${C_OFF}"$'\n'
    FRAME="${FRAME}${C_DIM}没有正在运行的 CI，下面是最近 $HISTORY 条：${C_OFF}"$'\n'
  else
    FRAME="${FRAME}${C_DIM}每 ${INTERVAL}s 刷新 · r 立即刷新 · q 退出${C_OFF}"$'\n'
  fi

  FRAME="${FRAME}${body}"

  # History, minus anything already drawn as running.
  local shown=0
  for id in $recent; do
    [ "$shown" -ge "$HISTORY" ] && break
    case "$running" in *"$id"*) continue ;; esac
    fields=$(run_fields "$id") || continue
    [ -z "$fields" ] && continue
    status=${fields%%$'\037'*}
    [ "$status" != "completed" ] && continue
    FRAME="${FRAME}$(draw_finished "$id" "$fields")"$'\n'
    shown=$(( shown + 1 ))
  done

  FRAME="${FRAME%$'\n'}"$'\n'
}

# Alternate screen, so the dashboard owns the window and leaving restores whatever was there.
SCREEN_ACTIVE=0
enter_screen() {
  [ "$ONCE" = 1 ] && return
  [ -t 1 ] || return
  printf '\033[?1049h\033[?25l'
  SCREEN_ACTIVE=1
}
leave_screen() {
  [ "$SCREEN_ACTIVE" = 1 ] || return
  printf '\033[?25h\033[?1049l'
  SCREEN_ACTIVE=0
}
trap 'leave_screen' EXIT INT TERM

render() {
  if [ "$SCREEN_ACTIVE" = 1 ]; then
    printf '\033[H%s\033[J' "$FRAME"
  else
    printf '%s\n' "$FRAME"
  fi
}

enter_screen
next_poll=0
failed_any=0

while :; do
  now=$(now_epoch)

  if [ "$now" -ge "$next_poll" ]; then
    build_frame
    if [ "$ANY_RUNNING" = 1 ]; then
      next_poll=$(( now + INTERVAL ))
    else
      next_poll=$(( now + IDLE_INTERVAL ))
    fi
    # Remember the worst conclusion seen this session; the exit code reports it.
    case "$FRAME" in *"${C_RED}失败"*) failed_any=1 ;; esac
    render
    [ "$ONCE" = 1 ] && break
  fi

  # One key, no echo. A pipe or a redirect means nobody is listening, so do not spin on EOF.
  if [ -t 0 ]; then
    key=""
    if read -rsn1 -t 1 key; then
      case "$key" in
        r|R) next_poll=0 ;;
        q|Q) break ;;
      esac
    fi
  else
    sleep 1
  fi
done

leave_screen
exit "$failed_any"
