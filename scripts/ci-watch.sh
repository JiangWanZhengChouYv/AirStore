#!/bin/bash
# A full-screen dashboard for every CI run in flight, plus the last few that finished.
#
#   ciw                      # watch, and keep watching after the queue empties
#   ciw --once               # one snapshot and exit (no alternate screen, safe to pipe)
#   ciw --all                # start with a longer history
#   ciw 39786651476 ...      # specific run ids
#   ciw -b develop -i 5      # one branch, refresh every 5s while runs are active
#   ciw --no-revive          # never re-queue anything by itself (see below)
#   ESTIMATE=600 ciw         # override the seconds a build is expected to take
#   QUEUE_TIMEOUT=600 MAX_DISPATCH=1 ciw   # tune the re-queue
#
# A run that has been sitting with no runner for over QUEUE_TIMEOUT seconds gets put back in the
# queue: the runner pool has been swallowing queued runs, and a run that never started loses nothing
# by re-queueing. Caps: MAX_REVIVE touches per run, MAX_DISPATCH dispatches in total, and no two
# touches within REVIVE_COOLDOWN seconds. The row says what was done.
#
# Keys: r = refresh now, q = quit, 1-9 = expand the Nth row. When nothing is running it keeps the
# finished runs on screen and checks again every three minutes, so a push made from another window
# shows up on its own.
#
# The bar is time based on purpose: one xcodebuild step is most of the run, so counting steps sits
# at 60% for nine minutes and then jumps. The estimate comes from this workflow's own recent
# completed runs, so it follows the repo's real history rather than a guess. A run with no steps at
# all has not been given a runner yet -- drawing a creeping bar there would be a lie, so it shows
# 排队中 and stays at zero.

set -uo pipefail

REPO="JiangWanZhengChouYv/AirStore"
# 60s, not 15: a build runs ~12 minutes, and asking the API every 15 seconds from every terminal
# that had one of these open burned through GitHub's 5000-an-hour budget in one evening. The bar does
# not need the traffic -- its percentage is computed from the clock against the run's measured
# duration on every redraw, so between polls it keeps advancing on its own.
INTERVAL=60
IDLE_INTERVAL=180
# Seconds a run may sit with no runner at all before this watcher puts it back in the queue, how many
# times it may do that to one run, how many dispatches the whole machine may have (a dispatch
# invents a run id the per-run counter has never seen), and the minimum gap between any two writes.
QUEUE_TIMEOUT=${QUEUE_TIMEOUT:-300}
MAX_REVIVE=${MAX_REVIVE:-2}
MAX_DISPATCH=${MAX_DISPATCH:-3}
REVIVE_COOLDOWN=${REVIVE_COOLDOWN:-180}
NO_REVIVE=0
REVIVE_STATE="${TMPDIR:-/tmp}/ciw-revive-state"
# 1 = this pass may spend API calls; 0 = redraw from the copies on disk. The screen is redrawn every
# second either way, and the percentage is derived from the clock at draw time -- so between polls the
# bar keeps moving while the network stays quiet.
FETCH=1
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
    -i|--interval) INTERVAL="${2:-60}"; shift ;;
    --no-revive) NO_REVIVE=1 ;;
    -h|--help)     sed -n '2,26p' "$0"; exit 0 ;;
    ''|--*)        ;;
    *[!0-9]*)      echo "ignoring '$1' (not a run id)" >&2 ;;
    *)             MODE="ids"; RUN_IDS+=("$1") ;;
  esac
  shift
done

[ "$INTERVAL" -gt 0 ] 2>/dev/null || INTERVAL=60

if [ -t 1 ]; then
  C_DIM=$(tput dim); C_RED=$(tput setaf 1); C_GRN=$(tput setaf 2)
  C_YEL=$(tput setaf 3); C_CYN=$(tput setaf 6); C_OFF=$(tput sgr0)
else
  C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_OFF=""
fi

COLS=${COLUMNS:-$(tput cols 2>/dev/null || echo 100)}
LINES=${LINES:-$(tput lines 2>/dev/null || echo 40)}
[ "$LINES" -gt 0 ] 2>/dev/null || LINES=40

# Everything before the bar is a fixed 57 cells: state(4) name(12) branch(10) sha(8) percent(4)
# steps(7) elapsed(5) plus the separators. Whatever is left gets split between the bar and the
# step name, so a row always ends on one line -- a wrapped row breaks the redraw accounting.
FIXED_CELLS=57
recalc_layout() {
  rest=$(( COLS - FIXED_CELLS - 3 ))
  [ "$rest" -lt 16 ] && rest=16
  BAR_WIDTH=$(( rest * 6 / 10 ))
  [ "$BAR_WIDTH" -lt 6 ] && BAR_WIDTH=6
  [ "$BAR_WIDTH" -gt 40 ] && BAR_WIDTH=40
  STEP_WIDTH=$(( rest - BAR_WIDTH ))
  [ "$STEP_WIDTH" -lt 8 ] && STEP_WIDTH=8
}
recalc_layout

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
# answers with nothing at all, which reads as "no CI is running". `pending` is a separate value and
# the one a run sits in when no runner has been assigned yet -- querying only `queued` makes exactly
# the stuck runs invisible.
running_ids() {
  if [ "$MODE" = "ids" ]; then
    printf '%s\n' "${RUN_IDS[@]}"
    return
  fi
  local cache="$DETAIL_CACHE_DIR/running.ids"
  if [ "$FETCH" = 0 ] && [ -f "$cache" ]; then cat "$cache"; return; fi
  local q="repos/$REPO/actions/runs?per_page=30"
  [ -n "$BRANCH" ] && q="$q&branch=$BRANCH"
  {
    gh api "$q&status=queued" --jq '.workflow_runs[].id' 2>/dev/null
    gh api "$q&status=pending" --jq '.workflow_runs[].id' 2>/dev/null
    gh api "$q&status=in_progress" --jq '.workflow_runs[].id' 2>/dev/null
  } | awk '!seen[$1]++' > "$cache"
  cat "$cache"
}

recent_ids() {
  local cache="$DETAIL_CACHE_DIR/recent.ids"
  if [ "$FETCH" = 0 ] && [ -f "$cache" ]; then cat "$cache"; return; fi
  local q="repos/$REPO/actions/runs?per_page=$(( HISTORY + 10 ))"
  [ -n "$BRANCH" ] && q="$q&branch=$BRANCH"
  gh api "$q" --jq ".workflow_runs[:$HISTORY][].id" 2>/dev/null > "$cache"
  cat "$cache"
}

run_fields() {
  local cache="$DETAIL_CACHE_DIR/fields.$1"
  if [ "$FETCH" = 0 ] && [ -f "$cache" ]; then cat "$cache"; return; fi
  gh api "repos/$REPO/actions/runs/$1" --jq \
    '[.status, (.conclusion // ""), .name, .head_branch, .head_sha, .run_started_at, .updated_at, (.run_attempt // 1|tostring), .path] | join("\u001f")' \
    2>/dev/null > "$cache"
  cat "$cache"
}

# A run that has never been handed a runner has lost nothing by going back to the front of the queue,
# and the pool has been swallowing queued runs whole. GitHub will not rerun anything that has not
# finished -- it answers "This workflow is already running (HTTP 403)" -- and the cancel that would
# unlock the rerun takes 20-25 seconds to land, which is a lot of frozen screen for nothing: this
# workflow's concurrency group cancels the stuck run the moment a new one is created (measured: the
# old run flipped to cancelled 8s after the fresh run appeared). So one dispatch is the whole action.
# It is allowed only when the stuck commit is still the branch head, so a re-queue can never quietly
# build a different revision than the row being watched; a stale commit gets dropped instead.
revive_run() {
  local id="$1" wf_file="$2" branch="$3" sha="$4" now last count head
  now=$(now_epoch)
  mkdir -p "$REVIVE_STATE" 2>/dev/null
  last=$(cat "$REVIVE_STATE/last" 2>/dev/null || echo 0)
  case "$last" in (''|*[!0-9]*) last=0 ;; esac
  [ $(( now - last )) -lt "$REVIVE_COOLDOWN" ] && return 1
  count=$(cat "$REVIVE_STATE/run.$id" 2>/dev/null || echo 0)
  case "$count" in (''|*[!0-9]*) count=0 ;; esac
  [ "$count" -ge "$MAX_REVIVE" ] && return 1

  local note
  # The per-run counter cannot bound this on its own: a dispatch creates a run with a brand new id,
  # which the next poll has never seen. So dispatches get their own ceiling -- three, then stop and
  # say so -- because a pool jammed this badly is not fixed by an endless line of fresh runs.
  local dispatches dispatched
  dispatches=$(cat "$REVIVE_STATE/dispatch.count" 2>/dev/null || echo 0)
  case "$dispatches" in (''|*[!0-9]*) dispatches=0 ;; esac
  # A counter that has not been touched in half a day describes a different afternoon's queue.
  [ -n "$(find "$REVIVE_STATE/dispatch.count" -mmin +720 2>/dev/null)" ] && dispatches=0

  head=$(gh api "repos/$REPO/commits?sha=$branch&per_page=1" --jq '.[0].sha' 2>/dev/null)
  if [ -z "$head" ]; then
    note="no branch head"
  elif [ "$head" != "$sha" ]; then
    gh run cancel "$id" --yes >/dev/null 2>&1 && note="dropped (newer push)" || note="cancel failed"
  elif [ "$dispatches" -ge "$MAX_DISPATCH" ]; then
    note="stopped after $dispatches"
  elif gh workflow run "$wf_file" --ref "$branch" >/dev/null 2>&1; then
    dispatched=$(( dispatches + 1 ))
    printf '%s\n' "$dispatched" > "$REVIVE_STATE/dispatch.count"
    note="re-dispatched $dispatched/$MAX_DISPATCH"
  else
    note="dispatch failed"
  fi

  printf '%s\n' "$(( count + 1 ))" > "$REVIVE_STATE/run.$id"
  printf '%s\n' "$now" > "$REVIVE_STATE/last"
  printf '%s' "$note"
}

# One queued run, seen once per session. The row keeps its note file so the action stays on screen
# instead of vanishing on the next poll.
maybe_revive() {
  local id="$1" fields="$2"
  [ "$NO_REVIVE" = 1 ] && return 1
  local IFS=$'\037'
  # shellcheck disable=SC2086
  set -- $fields
  unset IFS
  local status="$1" branch="$4" sha="$5" started="$6" wf_path="$9"
  case "$status" in queued|pending) ;; *) return 1 ;; esac
  [ -s "$DETAIL_CACHE_DIR/note.$id" ] && return 1
  local waited=$(( $(now_epoch) - $(to_epoch "$started") ))
  [ "$waited" -lt "$QUEUE_TIMEOUT" ] && return 1
  [ -z "${wf_path##*/}" ] && return 1
  local note
  note=$(revive_run "$id" "${wf_path##*/}" "$branch" "$sha") || return 1
  [ -n "$note" ] && printf '%s' "$note" > "$DETAIL_CACHE_DIR/note.$id"
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
  local stepsCache="$DETAIL_CACHE_DIR/stepsraw.$id"
  if [ "$FETCH" = 0 ] && [ -f "$stepsCache" ]; then
    steps=$(cat "$stepsCache")
  else
    steps=$(gh api "repos/$REPO/actions/runs/$id/jobs" --jq \
      '.jobs[].steps[] | "\(.status)\t\(.conclusion // "-")\t\(.name)"' 2>/dev/null)
    printf '%s' "$steps" > "$stepsCache"
  fi
  total=$(printf '%s\n' "$steps" | grep -c . )
  done_steps=$(printf '%s\n' "$steps" | grep -cE '^completed')
  current=$(printf '%s\n' "$steps" | awk -F'\t' '$1=="in_progress"{print $3; exit}')
  [ -z "$current" ] && current=$(printf '%s\n' "$steps" | awk -F'\t' '$1!="completed"{print $3; exit}')
  # Whether a runner has actually started work. Queued runs cost the same API calls as building
  # ones, so the poll interval is chosen from this; the caller reads it back out of the file.
  printf '%s' "$total" > "$DETAIL_CACHE_DIR/steps.$id" 2>/dev/null

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
  # The note replaces the label rather than following it: the column is width-clamped, and this shell
  # clamps by bytes under a C locale, so a CJK note would print half a character. Keep it ASCII. Only
  # while the run is still waiting, or it would hide the real step name once a runner takes it.
  if [ "$total" -eq 0 ] && [ -s "$DETAIL_CACHE_DIR/note.$id" ]; then
    label=$(cat "$DETAIL_CACHE_DIR/note.$id")
  fi
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
    "")        colour="$C_YEL"; state="收尾" ;;   # completed, conclusion not published yet
    cancelled) colour="$C_DIM"; state="取消" ;;   # superseded by a newer push on the same branch
    skipped)   colour="$C_DIM"; state="跳过" ;;
    *)         colour="$C_DIM"; state="结束" ;;
  esac

  local elapsed=$(( $(to_epoch "$updated") - $(to_epoch "$started") ))
  [ "$elapsed" -lt 0 ] && elapsed=0
  local mm=$(( elapsed / 60 )) ss=$(( elapsed % 60 ))

  local artifacts
  local artifactsCache="$DETAIL_CACHE_DIR/artifacts.$id"
  if [ "$FETCH" = 0 ] && [ -f "$artifactsCache" ]; then
    artifacts=$(cat "$artifactsCache")
  else
    artifacts=$(gh api "repos/$REPO/actions/runs/$id/artifacts" --jq '[.artifacts[].name] | join(" · ")' 2>/dev/null)
    printf '%s' "$artifacts" > "$artifactsCache"
  fi

  printf '%s%s%s %-12s %-10s %s  %02d:%02d  %s%s%s' \
    "$colour" "$state" "$C_OFF" "$(shorten_workflow "$workflow")" "${branch:0:10}" "${sha:0:8}" \
    "$mm" "$ss" "$C_DIM" "${artifacts:0:$(( COLS - 60 ))}" "$C_OFF"
}

EXPANDED_IDS="|"
DETAIL_CACHE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ciw-details.XXXXXX")

is_expanded() {
  case "$EXPANDED_IDS" in *"|$1|"*) return 0 ;; esac
  return 1
}

# Job/step lines for one run. Completed runs are cached; running ones are fetched again on each
# poll so their steps stay current.
details_for() {
  local id="$1" status="$2"
  local cache="$DETAIL_CACHE_DIR/$id" tmp="$DETAIL_CACHE_DIR/$id.$$"
  if [ "$status" = "completed" ] && [ -f "$cache" ]; then
    cat "$cache"
    return
  fi

  gh api "repos/$REPO/actions/runs/$id/jobs?per_page=10" --jq '
    .jobs[] |
    ("▸ " + .name + "  [" + (.conclusion // .status) + "]") as $job |
    $job,
    (.steps[]? | "   " + (if .conclusion == "failure" then "✗ " elif .conclusion == "success" then "✓ " elif .conclusion == "skipped" then "· " else "… " end) + .name)
  ' 2>/dev/null | head -n 14 > "$tmp"

  if [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    printf '%s\n' "（没有拉到详情，按 r 重试）"
    return
  fi

  if [ "$status" = "completed" ]; then
    mv "$tmp" "$cache"
    cat "$cache"
  else
    cat "$tmp"
    rm -f "$tmp"
  fi
}

append_frame_line() {
  # $1 run id (empty for headers), $2 text. One terminal line at most; stops at the window height.
  [ "${#LINE_IDS[@]}" -ge "$((LINES - 1))" ] && return 1
  FRAME="${FRAME}${2}"$'\n'
  FRAME_LINES[${#FRAME_LINES[@]}]="$2"
  LINE_IDS[${#LINE_IDS[@]}]="$1"
  return 0
}

# Rebuilds FRAME from whatever is running and the tail of the history. Sets ANY_RUNNING.
build_frame() {
  FRAME=""
  FRAME_LINES=()
  LINE_IDS=()
  ANY_RUNNING=0
  POLL_FAST=0
  HELP_INDEX=-1

  append_frame_line "" "${C_CYN}AirStore CI${C_OFF}  $(date '+%H:%M:%S')  "

  local running recent id fields status
  running=$(running_ids)
  recent=$(recent_ids)

  if [ -n "$running" ]; then
    ANY_RUNNING=1
    HELP_INDEX=${#FRAME_LINES[@]}
    append_frame_line "" "${C_DIM}每 ${INTERVAL}s 刷新 · r 刷新 · q 退出 · ⌘+ 放大${C_OFF}"
    append_frame_line "" "${C_DIM}1–9 展开/收起从上往下第 N 行${C_OFF}"
    for id in $running; do
      fields=$(run_fields "$id") || continue
      [ -z "$fields" ] && continue
      status=${fields%%$'\037'*}
      printf '%s' "$status" > "$DETAIL_CACHE_DIR/status.$id"
      append_frame_line "$id" "$(draw_run "$id" "$fields")" || break
      # A run that has not been given a runner yet has nothing to watch; asking every minute about
      # it is just traffic.
      if [ "$(cat "$DETAIL_CACHE_DIR/steps.$id" 2>/dev/null)" -gt 0 ] 2>/dev/null; then
        POLL_FAST=1
      elif [ "$FETCH" = 1 ] && maybe_revive "$id" "$fields"; then
        POLL_FAST=1     # something was just re-queued; look again on the short interval
      elif [ -s "$DETAIL_CACHE_DIR/note.$id" ]; then
        POLL_FAST=1     # still waiting for the outcome of the re-queue this session already did
      fi
      if is_expanded "$id"; then
        while IFS= read -r line; do
          append_frame_line "$id" "  ${C_DIM}${line:0:$((COLS - 4))}${C_OFF}" || break
        done < <(details_for "$id" "$status")
      fi
    done
  else
    HELP_INDEX=${#FRAME_LINES[@]}
    append_frame_line "" "${C_DIM}空闲 · 每 $(( IDLE_INTERVAL / 60 )) 分钟自检 · r 刷新 · q 退出 · ⌘+ 放大${C_OFF}"
    append_frame_line "" "${C_DIM}1–9 展开/收起从上往下第 N 行${C_OFF}"
    append_frame_line "" "${C_DIM}没有正在运行的 CI，下面是最近 $HISTORY 条：${C_OFF}"
  fi

  # History, minus anything already drawn as running.
  local shown=0
  for id in $recent; do
    [ "$shown" -ge "$HISTORY" ] && break
    case "$running" in *"$id"*) continue ;; esac
    fields=$(run_fields "$id") || continue
    [ -z "$fields" ] && continue
    status=${fields%%$'\037'*}
    [ "$status" != "completed" ] && continue
    printf '%s' "completed" > "$DETAIL_CACHE_DIR/status.$id"
    case "$fields" in
      *$'\037'$'\037'*) ANY_RUNNING=1; POLL_FAST=1 ;;   # conclusion still empty: poll again rather than call it 结束
    esac
    append_frame_line "$id" "$(draw_finished "$id" "$fields")" || break
    shown=$(( shown + 1 ))
    if is_expanded "$id"; then
      while IFS= read -r line; do
        append_frame_line "$id" "  ${C_DIM}${line:0:$((COLS - 4))}${C_OFF}" || break
      done < <(details_for "$id" "completed")
    fi
  done

  # The interval line is drawn before the rows, so it could not know whether anything actually
  # started. Fix it up now that the answer is known.
  if [ "$HELP_INDEX" -ge 0 ]; then
    local label
    if [ "$ANY_RUNNING" = 1 ] && [ "$POLL_FAST" = 0 ]; then
      label="等 runner · 每 $(( IDLE_INTERVAL / 60 )) 分钟刷新"
    elif [ "$ANY_RUNNING" = 1 ]; then
      label="每 ${INTERVAL}s 刷新"
    else
      label="空闲 · 每 $(( IDLE_INTERVAL / 60 )) 分钟自检"
    fi
    FRAME_LINES[$HELP_INDEX]="${C_DIM}${label} · r 刷新 · q 退出 · ⌘+ 放大${C_OFF}"
  fi
  frame_from_lines
}

frame_from_lines() {
  FRAME=""
  local i=0
  while [ "$i" -lt "${#FRAME_LINES[@]}" ]; do
    FRAME="${FRAME}${FRAME_LINES[$i]}"$'\n'
    i=$((i + 1))
  done
}

# Drops one run's detail lines but keeps its summary line. No API call: collapsing must be instant.
collapse_run() {
  local id="$1" i=0 seen=0 out_l=() out_i=()
  while [ "$i" -lt "${#LINE_IDS[@]}" ]; do
    if [ "${LINE_IDS[$i]}" = "$id" ]; then
      if [ "$seen" = 0 ]; then
        seen=1
        out_l[${#out_l[@]}]="${FRAME_LINES[$i]}"
        out_i[${#out_i[@]}]="$id"
      fi
    else
      out_l[${#out_l[@]}]="${FRAME_LINES[$i]}"
      out_i[${#out_i[@]}]="${LINE_IDS[$i]}"
    fi
    i=$((i + 1))
  done
  FRAME_LINES=("${out_l[@]}")
  LINE_IDS=("${out_i[@]}")
  frame_from_lines
}

# Inserts one run's details under its summary line, fetching them only if this session has not
# already cached them. Later polls refresh the whole frame anyway.
expand_run() {
  local id="$1" i=0 insert_after=-1
  while [ "$i" -lt "${#LINE_IDS[@]}" ]; do
    [ "${LINE_IDS[$i]}" = "$id" ] && insert_after=$i
    i=$((i + 1))
  done
  [ "$insert_after" -lt 0 ] && return 1
  if [ "${#LINE_IDS[@]}" -ge "$((LINES - 1))" ]; then
    show_status "窗口太矮，展开会把内容挤出屏幕；放大窗口或按 r 后再试"
    return 1
  fi

  local status=""
  [ -f "$DETAIL_CACHE_DIR/status.$id" ] && status=$(cat "$DETAIL_CACHE_DIR/status.$id")

  local details
  if [ "$status" = "completed" ] && [ -f "$DETAIL_CACHE_DIR/$id" ]; then
    details=$(cat "$DETAIL_CACHE_DIR/$id")
  else
    show_status "加载中… 正在拉取 #$id 的 job 和步骤"
    details=$(details_for "$id" "$status")
  fi

  local out_l=() out_i=() line
  i=0
  while [ "$i" -lt "${#LINE_IDS[@]}" ]; do
    [ "${#out_i[@]}" -ge "$((LINES - 1))" ] && break
    out_l[${#out_l[@]}]="${FRAME_LINES[$i]}"
    out_i[${#out_i[@]}]="${LINE_IDS[$i]}"
    if [ "$i" -eq "$insert_after" ]; then
      while IFS= read -r line; do
        [ "${#out_i[@]}" -ge "$((LINES - 1))" ] && break
        out_l[${#out_l[@]}]="  ${C_DIM}${line:0:$((COLS - 4))}${C_OFF}"
        out_i[${#out_i[@]}]="$id"
      done <<< "$details"
    fi
    i=$((i + 1))
  done
  FRAME_LINES=("${out_l[@]}")
  LINE_IDS=("${out_i[@]}")
  frame_from_lines
}

toggle_run() {
  local id="$1"
  [ -z "$id" ] && return
  if is_expanded "$id"; then
    EXPANDED_IDS=${EXPANDED_IDS//|$id|/|}
    collapse_run "$id"
  else
    EXPANDED_IDS="${EXPANDED_IDS}${id}|"
    if ! expand_run "$id"; then
      EXPANDED_IDS=${EXPANDED_IDS//|$id|/|}
      return
    fi
  fi
  render
}

# Keyboard: 1-9 toggles the nth run row from the top. Detail lines repeat their run's id, so count
# each id once or the numbering would drift as rows open.
handle_digit() {
  local n="$1" count=0 last="" id
  for id in "${LINE_IDS[@]}"; do
    [ -z "$id" ] && continue
    [ "$id" = "$last" ] && continue
    last="$id"
    count=$(( count + 1 ))
    if [ "$count" -eq "$n" ]; then
      toggle_run "$id"
      return
    fi
  done
}

# Alternate screen, so the dashboard owns the window and leaving restores whatever was there.
SCREEN_ACTIVE=0
RAW_MODE=0
STTY_STATE=""
enter_screen() {
  [ "$ONCE" = 1 ] && return
  [ -t 1 ] || return
  STTY_STATE=$(stty -g 2>/dev/null || true)
  # Single keys without Enter, and nothing echoed back into the frame.
  if [ -n "$STTY_STATE" ] && stty -echo -icanon min 1 time 0 2>/dev/null; then
    RAW_MODE=1
  fi
  printf '\033[?1049h\033[?25l'
  SCREEN_ACTIVE=1
}
leave_screen() {
  [ "$SCREEN_ACTIVE" = 1 ] || return
  printf '\033[?25h\033[?1049l'
  [ -n "$STTY_STATE" ] && stty "$STTY_STATE" 2>/dev/null
  SCREEN_ACTIVE=0
}
trap 'rm -rf "$DETAIL_CACHE_DIR"; leave_screen' EXIT
trap 'leave_screen; exit 130' INT TERM

render() {
  if [ "$SCREEN_ACTIVE" = 1 ]; then
    # Clear first, then draw. Erasing only after the final cursor (the old version) left the tails
    # of long or wrapped rows inside earlier lines when the new frame was shorter.
    printf '\033[H\033[J%s\033[J' "$FRAME"
  else
    printf '%s\n' "$FRAME"
  fi
}

# Bottom-row message while a slow rebuild runs, so a click never looks ignored. The next full
# render clears it along with the rest of the screen.
show_status() {
  [ "$SCREEN_ACTIVE" = 1 ] || return
  printf '\033[%d;1H\033[K%s%s%s' "$LINES" "$C_YEL" "$1" "$C_OFF"
}

enter_screen
# The first frame is several API calls deep; without this the alternate screen sits blank.
if [ "$SCREEN_ACTIVE" = 1 ]; then
  show_status "加载中… 正在读取正在跑的和最近的 CI"
fi
next_poll=0
failed_any=0

while :; do
  # Re-flow once a second so a ⌘+ font change (or a window resize) takes effect within 1s.
  if [ "$SCREEN_ACTIVE" = 1 ]; then
    new_cols=$(tput cols 2>/dev/null || echo "$COLS")
    new_lines=$(tput lines 2>/dev/null || echo "$LINES")
    if [ "$new_cols" != "$COLS" ] || [ "$new_lines" != "$LINES" ]; then
      COLS=$new_cols
      LINES=$new_lines
      [ "$LINES" -gt 0 ] 2>/dev/null || LINES=40
      recalc_layout
      next_poll=0
    fi
  fi

  now=$(now_epoch)

  if [ "$now" -ge "$next_poll" ]; then
    FETCH=1
    build_frame
    if [ "$ANY_RUNNING" = 1 ] && [ "$POLL_FAST" = 1 ]; then
      next_poll=$(( now + INTERVAL ))
    else
      next_poll=$(( now + IDLE_INTERVAL ))
    fi
    # Remember the worst conclusion seen this session; the exit code reports it.
    case "$FRAME" in *"${C_RED}失败"*) failed_any=1 ;; esac
    render
    [ "$ONCE" = 1 ] && break
  else
    # This pass asks GitHub nothing. The rows come back out of the copies on disk and the percentage
    # is derived from the clock again on the way out, so the bar and the elapsed time keep advancing
    # between polls. Only a real screen is redrawn: a redirected log should keep one frame per poll
    # instead of filling up with a copy a second.
    FETCH=0
    build_frame
    if [ "$SCREEN_ACTIVE" = 1 ]; then render; fi
  fi

  # One key, no echo. A pipe or a redirect means nobody is listening, so do not spin on EOF.
  if [ -t 0 ] && [ "$RAW_MODE" = 1 ]; then
    key=""
    if read -rsn1 -t 1 key; then
      case "$key" in
        r|R) show_status "刷新中…"; next_poll=0 ;;
        q|Q) break ;;
        [1-9]) handle_digit "$key" ;;
      esac
    fi
  else
    sleep 1
  fi
done

leave_screen
exit "$failed_any"
