#!/usr/bin/env bash
# tests/fm-watch-cmux.test.sh - the cmux worker path of the always-on watcher
# (bin/fm-watch.sh). Phase B slice 1 routes the watcher's stale-pane supervision
# through the terminal boundary (bin/fm-terminal-lib.sh), so a cmux worker - which
# records terminal_backend=cmux + workspace/surface and NO window= - is enumerated,
# has its screen read through `cmux read-screen`, and is classified (busy footer,
# stale-with-outcome) the same way a tmux window is.
#
# These cases drive a real fm-watch.sh subprocess with a stubbed `cmux` (as
# tests/fm-terminal-cmux.test.sh stubs it for spawn) and assert:
#   - a cmux-meta task is ENUMERATED and its screen READ through the boundary;
#   - a busy footer on the cmux screen is NOT stale (absorbed);
#   - a stale cmux worker sitting on a done/needs-decision/failed STATUS is surfaced;
#   - a stale cmux worker whose OUTCOME marker is only on the screen is classified
#     via the real fm-crew-state.sh (screen-read fallback) and surfaced;
#   - the tmux worker path is unchanged and never touches cmux.
#
# The generic tmux triage matrix lives in fm-watch-triage.test.sh; cmux backend
# routing for send/peek in fm-terminal-cmux.test.sh; crew-state reads in
# fm-crew-state.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-cmux-tests)

# --- local helpers (mirror fm-watch-triage.test.sh) -------------------------

# Wait up to <limit> 0.1s ticks while <pid> stays alive; 0 if still alive, 1 if died.
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# Signature a primed .seen-* marker must hold so the per-poll signal scan does not
# fire on a pre-existing status (mirrors fm-watch.sh's stat_sig exactly).
seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

# A fake cmux that logs every invocation and serves a controllable screen. Mirrors
# the spawn stub in fm-terminal-cmux.test.sh; read-screen echoes CMUX_FAKE_SCREEN so
# a test can inject a busy footer or an outcome marker into the worker's screen.
install_cmux_stub() {  # <fakebin>
  cat > "$1/cmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${CMUX_FAKE_LOG:-/dev/null}"
case "${1:-}" in
  ping) exit 0 ;;
  read-screen) printf '%s\n' "${CMUX_FAKE_SCREEN:-idle prompt}"; exit 0 ;;
  send|send-key|close-surface) exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$1/cmux"
}

# A cmux task's meta: terminal_backend=cmux + workspace/surface, and crucially NO
# window= (the thing that used to make cmux workers invisible to the stale loop).
write_cmux_meta() {  # <state> <id> <worktree>
  fm_write_meta "$1/$2.meta" \
    'terminal_backend=cmux' \
    'workspace=workspace:1' \
    'surface=surface:2' \
    'pane=pane:3' \
    "worktree=$3" \
    'harness=pi' \
    'kind=ship' \
    'mode=local-only'
}

# The stale-loop marker key for a cmux worker token (fm-<id>), matching fm-watch.sh.
cmux_key() { printf '%s' "fm-$1" | tr ':/.' '___'; }

# Prime a matching stale hash + count so the stale path fires on the first poll,
# exactly as the tmux stale cases in fm-watch-triage.test.sh do.
prime_stale() {  # <state> <id> <screen>
  local key; key=$(cmux_key "$2")
  printf '%s' "$(hash_text "$3")" > "$1/.hash-$key"
  printf '1\n' > "$1/.count-$key"
}

# --- enumeration + boundary read + not-working stale surfaced ---------------

test_cmux_enumerated_and_read_through_boundary() {
  local dir state fakebin out drain_out cmux_log wt screen pid
  dir=$(make_case cmux-enum); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; cmux_log="$dir/cmux.log"
  wt="$dir/wt"; mkdir -p "$wt"
  install_cmux_stub "$fakebin"
  write_cmux_meta "$state" cmuxtask "$wt"
  screen='worker idle prompt'
  prime_stale "$state" cmuxtask "$screen"
  # No running pipeline, not busy: the worker has stopped -> NOT provably working
  # -> surface (the stubbed crew-state returns an unknown verdict).
  PATH="$fakebin:$PATH" CMUX_FAKE_LOG="$cmux_log" CMUX_FAKE_SCREEN="$screen" \
    FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface a stopped stale cmux worker"
  grep -Fx "stale: fm-cmuxtask" "$out" >/dev/null || fail "watcher did not print the cmux stale wake (got: $(cat "$out"))"
  # The screen was read through the terminal boundary with the recorded handles.
  assert_grep 'read-screen --workspace workspace:1 --surface surface:2 --lines 40' "$cmux_log" \
    "watcher did not read the cmux screen through the terminal boundary"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the cmux stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "fm-cmuxtask" >/dev/null || fail "cmux stale wake was not queued"
  pass "watcher enumerates a cmux worker, reads its screen through the boundary, and surfaces a stopped stale worker"
}

# --- busy footer on the cmux screen is not stale (absorbed) ------------------

test_cmux_busy_footer_absorbed() {
  local dir state fakebin out cmux_log wt screen pid
  dir=$(make_case cmux-busy); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; cmux_log="$dir/cmux.log"; wt="$dir/wt"; mkdir -p "$wt"
  install_cmux_stub "$fakebin"
  write_cmux_meta "$state" cmuxtask "$wt"
  # A busy footer on the cmux screen: the worker is mid-turn, so a stable pane is
  # not a stale worker. The inline busy grep runs on the boundary-read screen text.
  screen='building things
Working...'
  prime_stale "$state" cmuxtask "$screen"
  PATH="$fakebin:$PATH" CMUX_FAKE_LOG="$cmux_log" CMUX_FAKE_SCREEN="$screen" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then reap "$pid"; fail "watcher exited for a busy cmux worker (should absorb): $(cat "$out")"; fi
  [ ! -s "$out" ] || { reap "$pid"; fail "busy cmux worker printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "busy cmux worker enqueued a durable wake record"; }
  # It still read the screen through the boundary to make the busy call.
  assert_grep 'read-screen --workspace workspace:1 --surface surface:2 --lines 40' "$cmux_log" \
    "busy classification did not read the cmux screen through the terminal boundary"
  reap "$pid"
  pass "a cmux worker showing a busy footer is not stale (absorbed), classified from the boundary-read screen"
}

# --- stale cmux worker on a captain-relevant STATUS is surfaced --------------
# The status file stays the primary outcome signal; this proves the STALE path now
# covers cmux workers (they were previously invisible to it for lack of a window=).

run_terminal_outcome_case() {  # <casename> <status-line>
  local name=$1 status=$2 dir state fakebin out drain_out cmux_log wt screen sig pid
  dir=$(make_case "$name"); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; cmux_log="$dir/cmux.log"
  wt="$dir/wt"; mkdir -p "$wt"
  install_cmux_stub "$fakebin"
  write_cmux_meta "$state" cmuxtask "$wt"
  screen='idle, awaiting review'
  # The captain-relevant outcome is in the STATUS file; prime .seen-* so the signal
  # scan stays quiet and the STALE path is the one that classifies this worker.
  printf '%s\n' "$status" > "$state/cmuxtask.status"
  sig=$(seen_sig "$state/cmuxtask.status"); printf '%s' "$sig" > "$state/.seen-cmuxtask_status"
  prime_stale "$state" cmuxtask "$screen"
  PATH="$fakebin:$PATH" CMUX_FAKE_LOG="$cmux_log" CMUX_FAKE_SCREEN="$screen" \
    FM_FAKE_CREW_STATE='state: unknown · source: none · fake' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface a stale cmux worker on '$status'"
  grep -Fx "stale: fm-cmuxtask" "$out" >/dev/null || fail "watcher did not print the cmux terminal stale wake for '$status' (got: $(cat "$out"))"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain failed for '$status'"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F 'fm-cmuxtask' >/dev/null || fail "cmux terminal stale not queued for '$status'"
}

test_cmux_terminal_outcome_surfaced() {
  run_terminal_outcome_case cmux-term-done  'done: ready in branch fm/x'
  run_terminal_outcome_case cmux-term-needs 'needs-decision: pick A or B'
  run_terminal_outcome_case cmux-term-fail  'failed: build broke with evidence'
  pass "a stale cmux worker sitting on a done/needs-decision/failed status is surfaced (outcome classification)"
}

# --- outcome marker only on the cmux SCREEN, classified via real fm-crew-state ---
# When no captain-relevant status verb exists, the screen-read fallback must catch
# the outcome: the real fm-crew-state.sh reads the cmux screen through the boundary,
# classifies a needs-decision marker as parked (NOT provably working), and the
# watcher surfaces it. Exercises the whole enumeration -> boundary read -> classify
# chain end to end (no stubbed verdict).

test_cmux_screen_marker_surfaced_via_crew_state() {
  local dir state fakebin out drain_out cmux_log wt screen pid
  dir=$(make_case cmux-screen-marker); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; cmux_log="$dir/cmux.log"
  # A plain (non-git) worktree: crew-state finds no branch/run and falls to its
  # pane/marker read, which for cmux is a boundary screen read.
  wt="$dir/wt"; mkdir -p "$wt"
  install_cmux_stub "$fakebin"
  write_cmux_meta "$state" cmuxtask "$wt"
  # The outcome marker is ONLY on the screen (no captain-relevant status verb).
  screen='waiting for input
needs-decision: choose the database'
  prime_stale "$state" cmuxtask "$screen"
  PATH="$fakebin:$PATH" CMUX_FAKE_LOG="$cmux_log" CMUX_FAKE_SCREEN="$screen" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$ROOT/bin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 60 || fail "watcher did not surface a cmux worker whose screen shows a needs-decision marker"
  grep -Fx "stale: fm-cmuxtask" "$out" >/dev/null || fail "watcher did not print the cmux screen-marker stale wake (got: $(cat "$out"))"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the cmux screen-marker failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F 'fm-cmuxtask' >/dev/null || fail "cmux screen-marker stale was not queued"
  pass "a cmux worker whose screen shows a needs-decision outcome is classified via the terminal boundary (real fm-crew-state) and surfaced"
}

# --- the tmux worker path is unchanged and never touches cmux ----------------

test_tmux_path_unchanged_alongside_cmux_support() {
  local dir state fakebin out drain_out cmux_log capture window key h sig pid
  dir=$(make_case cmux-tmux-unchanged); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; cmux_log="$dir/cmux.log"; capture="$dir/pane.txt"
  install_cmux_stub "$fakebin"
  window='test:fm-tmuxtask'
  printf 'finished, awaiting review' > "$capture"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/tmuxtask.meta"
  printf 'done: PR https://example.test/pr/9\n' > "$state/tmuxtask.status"
  sig=$(seen_sig "$state/tmuxtask.status"); printf '%s' "$sig" > "$state/.seen-tmuxtask_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  h=$(hash_text 'finished, awaiting review')
  printf '%s' "$h" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" CMUX_FAKE_LOG="$cmux_log" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface a stale tmux worker (tmux path regressed)"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print the tmux stale wake (got: $(cat "$out"))"
  # A tmux worker is read through tmux, never cmux: the cmux stub must stay untouched.
  [ ! -s "$cmux_log" ] || fail "the tmux worker path invoked cmux (should stay tmux-only): $(cat "$cmux_log")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the tmux stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "tmux stale wake was not queued"
  pass "the tmux worker path is unchanged (read through tmux, cmux never invoked) alongside cmux support"
}

test_cmux_enumerated_and_read_through_boundary
test_cmux_busy_footer_absorbed
test_cmux_terminal_outcome_surfaced
test_cmux_screen_marker_surfaced_via_crew_state
test_tmux_path_unchanged_alongside_cmux_support
