#!/usr/bin/env bash
# cmux terminal backend routing for send/peek.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-terminal-cmux)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
HOME_DIR="$TMP_ROOT/home"
STATE_DIR="$HOME_DIR/state"
CONFIG_DIR="$HOME_DIR/config"
LOG="$TMP_ROOT/cmux.log"
mkdir -p "$STATE_DIR" "$CONFIG_DIR" "$TMP_ROOT/wt" "$TMP_ROOT/project"

cat > "$FAKEBIN/cmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CMUX_FAKE_LOG"
case "$1" in
  ping) exit 0 ;;
  read-screen) printf 'done: fake cmux output\n'; exit 0 ;;
  send|send-key|close-surface) printf 'OK surface:2 workspace:1\n'; exit 0 ;;
  new-split|new-pane|new-surface) printf 'created surface:7 workspace:1\n'; exit 0 ;;
  new-window) printf 'created window:2\n'; exit 0 ;;
  current-window) printf 'window:2\n'; exit 0 ;;
  new-workspace) printf 'created workspace:9\n'; exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$FAKEBIN/cmux"

write_cmux_meta() {
  fm_write_meta "$STATE_DIR/task.meta" \
    'terminal_backend=cmux' \
    'workspace=workspace:1' \
    'surface=surface:2' \
    'worktree='"$TMP_ROOT"/wt \
    'project='"$TMP_ROOT"/project \
    'harness=pi' \
    'kind=ship' \
    'mode=local-only'
}

test_peek_uses_cmux_read_screen() {
  write_cmux_meta
  : > "$LOG"
  out=$(PATH="$FAKEBIN:$PATH" CMUX_FAKE_LOG="$LOG" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" FM_CONFIG_OVERRIDE="$CONFIG_DIR" \
    "$ROOT/bin/fm-peek.sh" fm-task 5 2>/dev/null) || fail "fm-peek failed for cmux target"
  assert_contains "$out" 'done: fake cmux output' "fm-peek did not return cmux read-screen output"
  assert_grep 'read-screen --workspace workspace:1 --surface surface:2 --lines 5' "$LOG" "fm-peek did not call cmux read-screen with recorded handles"
  pass "fm-peek routes terminal_backend=cmux targets through cmux read-screen"
}

test_send_uses_cmux_send_and_newline() {
  write_cmux_meta
  : > "$LOG"
  PATH="$FAKEBIN:$PATH" CMUX_FAKE_LOG="$LOG" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" FM_CONFIG_OVERRIDE="$CONFIG_DIR" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" fm-task 'echo hello' >/dev/null 2>/dev/null || fail "fm-send failed for cmux target"
  assert_grep 'send --workspace workspace:1 --surface surface:2 echo hello\n' "$LOG" "fm-send did not submit text with trailing newline through cmux"
  pass "fm-send routes cmux targets through cmux send with submit newline"
}

test_send_key_maps_ctrl_c() {
  write_cmux_meta
  : > "$LOG"
  PATH="$FAKEBIN:$PATH" CMUX_FAKE_LOG="$LOG" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" FM_CONFIG_OVERRIDE="$CONFIG_DIR" \
    "$ROOT/bin/fm-send.sh" fm-task --key C-c >/dev/null 2>/dev/null || fail "fm-send --key failed for cmux target"
  assert_grep 'send-key --workspace workspace:1 --surface surface:2 ctrl+c' "$LOG" "fm-send did not map C-c to cmux ctrl+c"
  pass "fm-send maps tmux-style C-c to cmux ctrl+c"
}

# --- multi-worker layout policy --------------------------------------------

# Seed <count> existing cmux worker metas, each recording the crew pane so a tab
# overflow has an unambiguous target. Clears prior worker metas first.
seed_cmux_workers() {  # <count> [pane]
  local count=$1 pane=${2:-pane:9} i=1
  # Clear ALL metas (including task.meta left by the send/peek tests) so the live
  # cmux worker count is exactly <count>.
  rm -f "$STATE_DIR"/*.meta
  while [ "$i" -le "$count" ]; do
    fm_write_meta "$STATE_DIR/worker-$i.meta" \
      'terminal_backend=cmux' \
      "pane=$pane" \
      "surface=surface:$i" \
      'kind=ship'
    i=$((i + 1))
  done
}

# Seed <count> existing cmux workers with distinct, creation-ordered surfaces
# (surface:11, surface:12, ...) so grid anchor assertions are unambiguous vs the
# firstmate caller surface. No workspace is recorded, so grid placement falls back
# to the passed workspace (a single-window grid). Clears prior worker metas first.
seed_grid_workers() {  # <count>
  local count=$1 i=1
  rm -f "$STATE_DIR"/*.meta
  while [ "$i" -le "$count" ]; do
    fm_write_meta "$STATE_DIR/gw-$i.meta" \
      'terminal_backend=cmux' \
      "surface=surface:$((10 + i))" \
      'kind=ship'
    i=$((i + 1))
  done
}

# Run fm_terminal_cmux_place_worker from the lib with STATE/cmux stub wired up.
place() {  # <workspace> <caller_surface> <layout> <exclude-id>
  STATE="$STATE_DIR" PATH="$FAKEBIN:$PATH" CMUX_FAKE_LOG="$LOG" \
    bash -c '. "$1"; shift; fm_terminal_cmux_place_worker "$@"' _ "$ROOT/bin/fm-terminal-lib.sh" "$@"
}

# Run a pure lib function (no cmux) for the arithmetic unit tests.
action() { bash -c '. "$1"; fm_terminal_cmux_layout_action "$2" "$3"' _ "$ROOT/bin/fm-terminal-lib.sh" "$@"; }
slot() { bash -c '. "$1"; fm_terminal_cmux_grid_slot "$2"' _ "$ROOT/bin/fm-terminal-lib.sh" "$@"; }

test_layout_action_grid_and_window() {
  local a n
  # auto: grid within a window, overflow to a new window each time it fills (cap 4).
  for n in 0 1 2 3; do a=$(action auto "$n"); [ "$a" = grid ] || fail "auto N=$n expected grid, got '$a'"; done
  a=$(action auto 4); [ "$a" = window ] || fail "auto N=4 expected window, got '$a'"
  for n in 5 6 7; do a=$(action auto "$n"); [ "$a" = grid ] || fail "auto N=$n expected grid, got '$a'"; done
  a=$(action auto 8); [ "$a" = window ] || fail "auto N=8 expected window, got '$a'"
  # capacity is tunable: at cap 2, the boundary moves to N=2.
  a=$(FM_CMUX_GRID_CAPACITY=2 bash -c '. "$1"; fm_terminal_cmux_layout_action "$2" "$3"' _ "$ROOT/bin/fm-terminal-lib.sh" auto 2)
  [ "$a" = window ] || fail "auto N=2 at capacity 2 expected window, got '$a'"
  # splits/tabs/hybrid keep their pre-grid shapes.
  a=$(action splits 5); [ "$a" = split ] || fail "splits expected split, got '$a'"
  a=$(action tabs 0); [ "$a" = split ] || fail "tabs N=0 expected split, got '$a'"
  a=$(action tabs 1); [ "$a" = tab ] || fail "tabs N=1 expected tab, got '$a'"
  a=$(action hybrid 2); [ "$a" = split ] || fail "hybrid N=2 expected split, got '$a'"
  a=$(action hybrid 3); [ "$a" = tab ] || fail "hybrid N=3 expected tab, got '$a'"
  pass "layout_action: auto grid/window boundary at capacity (tunable); splits/tabs/hybrid unchanged"
}

test_grid_slot_arithmetic() {
  local s
  # First grid (2x2): right off firstmate, down off W1, right off W1, down off W3.
  s=$(slot 0); [ "$s" = 'right caller' ] || fail "slot 0 expected 'right caller', got '$s'"
  s=$(slot 1); [ "$s" = 'down 0' ] || fail "slot 1 expected 'down 0', got '$s'"
  s=$(slot 2); [ "$s" = 'right 0' ] || fail "slot 2 expected 'right 0', got '$s'"
  s=$(slot 3); [ "$s" = 'down 2' ] || fail "slot 3 expected 'down 2', got '$s'"
  # Second grid (a new window): anchors are GLOBAL creation indices, never caller.
  s=$(slot 5); [ "$s" = 'down 4' ] || fail "slot 5 expected 'down 4', got '$s'"
  s=$(slot 6); [ "$s" = 'right 4' ] || fail "slot 6 expected 'right 4', got '$s'"
  s=$(slot 7); [ "$s" = 'down 6' ] || fail "slot 7 expected 'down 6', got '$s'"
  pass "grid_slot: right/down alternation, caller anchor only for worker 1, global anchors across windows"
}

test_auto_grid_then_new_window() {
  # Worker 1 (0 existing): split RIGHT off firstmate's caller surface (top-right).
  seed_grid_workers 0; : > "$LOG"
  place workspace:1 surface:5 auto newtask >/dev/null || fail "auto grid placement failed at N=0"
  assert_grep 'new-split right --workspace workspace:1 --surface surface:5 --focus false' "$LOG" "grid worker 1 was not a right split off firstmate"
  assert_no_grep 'new-window' "$LOG" "grid worker 1 wrongly opened a new window"
  assert_no_grep 'new-surface' "$LOG" "grid worker 1 overflowed to a tab"
  # Worker 2 (1 existing): split DOWN off worker 1 (surface:11) -> bottom of column 1.
  seed_grid_workers 1; : > "$LOG"; place workspace:1 surface:5 auto newtask >/dev/null
  assert_grep 'new-split down --workspace workspace:1 --surface surface:11 --focus false' "$LOG" "grid worker 2 did not split down off worker 1"
  # Worker 3 (2 existing): split RIGHT off worker 1 (surface:11) -> top of column 2.
  seed_grid_workers 2; : > "$LOG"; place workspace:1 surface:5 auto newtask >/dev/null
  assert_grep 'new-split right --workspace workspace:1 --surface surface:11 --focus false' "$LOG" "grid worker 3 did not split right off worker 1"
  # Worker 4 (3 existing): split DOWN off worker 3 (surface:13) -> bottom of column 2.
  seed_grid_workers 3; : > "$LOG"; place workspace:1 surface:5 auto newtask >/dev/null
  assert_grep 'new-split down --workspace workspace:1 --surface surface:13 --focus false' "$LOG" "grid worker 4 did not split down off worker 3"
  # firstmate's own surface (surface:5) anchors ONLY worker 1: later workers split
  # off prior WORKERS, so firstmate is pinned left and never sliced into a strip.
  assert_no_grep 'surface:5' "$LOG" "grid worker 4 sliced firstmate's own surface"
  # Worker 5 (4 existing = capacity): overflow to a NEW window, not a split/tab.
  seed_grid_workers 4; : > "$LOG"; place workspace:1 surface:5 auto newtask >/dev/null
  assert_grep 'new-window' "$LOG" "grid worker 5 did not overflow to a new window at capacity"
  assert_no_grep 'new-split' "$LOG" "grid worker 5 wrongly created a split at capacity"
  assert_no_grep 'new-surface' "$LOG" "grid worker 5 wrongly created a tab at capacity"
  pass "auto layout: 2x2 grid (right/down/right/down off firstmate then workers), new window at capacity"
}

test_auto_overflow_new_window_shape() {
  # At capacity the overflow builds a worker surface in a fresh window: new-window,
  # then a workspace in it, then a terminal pane. It echoes both the new surface and
  # the new window's workspace so the spawner addresses the worker in its own window.
  seed_grid_workers 4; : > "$LOG"
  local out
  out=$(place workspace:1 surface:5 auto newtask) || fail "new-window overflow placement failed"
  assert_grep 'new-window' "$LOG" "overflow did not create a new window"
  assert_grep 'new-workspace --window window:2 --focus false' "$LOG" "overflow did not create a workspace in the new window"
  assert_grep 'new-pane --type terminal --direction right --workspace workspace:9 --focus false' "$LOG" "overflow did not create a terminal pane in the new workspace"
  assert_contains "$out" 'surface:7' "new-window placement did not echo the worker surface"
  assert_contains "$out" 'workspace:9' "new-window placement did not echo the new window's workspace"
  pass "auto overflow: new window -> workspace -> terminal pane, echoing the new surface + workspace"
}

test_grid_anchor_uses_recorded_workspace() {
  # A worker that lives in a new window records its own workspace. When a later
  # worker tiles beside it, the split must be addressed in THAT workspace, not
  # firstmate's, so grid tiling is correct across windows.
  rm -f "$STATE_DIR"/*.meta; : > "$LOG"
  local i=1
  while [ "$i" -le 4 ]; do
    fm_write_meta "$STATE_DIR/gw-$i.meta" 'terminal_backend=cmux' "surface=surface:$((10 + i))" 'workspace=workspace:1' 'kind=ship'
    i=$((i + 1))
  done
  # Worker 5 lives in the NEW window's workspace:9.
  fm_write_meta "$STATE_DIR/gw-5.meta" 'terminal_backend=cmux' 'surface=surface:15' 'workspace=workspace:9' 'kind=ship'
  # Worker 6 (5 existing): grid_slot(5) = 'down 4' -> split down off worker 5,
  # addressed in worker 5's own workspace (workspace:9).
  place workspace:1 surface:5 auto newtask >/dev/null
  assert_grep 'new-split down --workspace workspace:9 --surface surface:15 --focus false' "$LOG" "second-window grid did not anchor in the prior worker's recorded workspace"
  pass "grid anchors off the prior worker's own recorded workspace (correct across windows)"
}

test_explicit_layout_modes() {
  # splits: always a split, even past the threshold
  seed_cmux_workers 5; : > "$LOG"; place workspace:1 surface:1 splits newtask >/dev/null
  assert_grep 'new-split right' "$LOG" "splits mode did not form a split at N=5"
  assert_no_grep 'new-surface' "$LOG" "splits mode overflowed to a tab"
  # tabs: first worker splits to create the crew pane, later workers become tabs
  seed_cmux_workers 0; : > "$LOG"; place workspace:1 surface:1 tabs newtask >/dev/null
  assert_grep 'new-split right' "$LOG" "tabs mode N=0 did not open a visible split"
  seed_cmux_workers 1; : > "$LOG"; place workspace:1 surface:1 tabs newtask >/dev/null
  assert_grep 'new-surface --type terminal --pane pane:9' "$LOG" "tabs mode N=1 did not overflow to a tab"
  # hybrid: same threshold as auto (split < 3, tab >= 3)
  seed_cmux_workers 2; : > "$LOG"; place workspace:1 surface:1 hybrid newtask >/dev/null
  assert_grep 'new-split right' "$LOG" "hybrid N=2 was not a split"
  seed_cmux_workers 3; : > "$LOG"; place workspace:1 surface:1 hybrid newtask >/dev/null
  assert_grep 'new-surface --type terminal --pane pane:9' "$LOG" "hybrid N=3 did not overflow to a tab"
  pass "explicit splits/tabs/hybrid layouts form the expected commands"
}

test_focus_never_stolen() {
  # grid split off firstmate (worker 1) passes --focus false
  seed_grid_workers 0; : > "$LOG"; place workspace:1 surface:5 auto newtask >/dev/null
  assert_grep 'new-split right --workspace workspace:1 --surface surface:5 --focus false' "$LOG" "grid split placement stole focus"
  # a later grid split (worker 4) also passes --focus false
  seed_grid_workers 3; : > "$LOG"; place workspace:1 surface:5 auto newtask >/dev/null
  assert_grep '--focus false' "$LOG" "later grid split did not pass --focus false"
  # new-window overflow: every command that CAN take --focus false does (cmux
  # new-window itself is bare and has no --focus flag).
  seed_grid_workers 4; : > "$LOG"; place workspace:1 surface:5 auto newtask >/dev/null
  assert_grep 'new-workspace --window window:2 --focus false' "$LOG" "new-window workspace did not pass --focus false"
  assert_grep 'new-pane --type terminal --direction right --workspace workspace:9 --focus false' "$LOG" "new-window pane did not pass --focus false"
  # tab overflow (explicit tabs layout) passes --focus false
  seed_cmux_workers 1; : > "$LOG"; place workspace:1 surface:1 tabs newtask >/dev/null
  assert_grep '--focus false' "$LOG" "tab placement did not pass --focus false"
  # no caller surface -> new-pane fallback, still --focus false
  seed_grid_workers 0; : > "$LOG"; place workspace:1 '' auto newtask >/dev/null
  assert_grep 'new-pane --type terminal --direction right --workspace workspace:1 --focus false' "$LOG" "empty caller surface did not fall back to new-pane"
  pass "placement never steals focus (--focus false on grid splits, new-window workspace/pane, tab, and fallback pane)"
}

test_invalid_layout_errors() {
  printf 'bogus\n' > "$CONFIG_DIR/cmux-layout"
  err=$(FM_CONFIG_OVERRIDE="$CONFIG_DIR" \
    bash -c '. "$1"; fm_terminal_cmux_layout' _ "$ROOT/bin/fm-terminal-lib.sh" 2>&1)
  code=$?
  rm -f "$CONFIG_DIR/cmux-layout"
  expect_code 2 "$code" "invalid cmux-layout did not exit 2"
  assert_contains "$err" 'invalid cmux layout' "invalid cmux-layout error message unclear"
  pass "invalid config/cmux-layout errors clearly"
}

test_peek_uses_cmux_read_screen
test_send_uses_cmux_send_and_newline
test_send_key_maps_ctrl_c
test_layout_action_grid_and_window
test_grid_slot_arithmetic
test_auto_grid_then_new_window
test_auto_overflow_new_window_shape
test_grid_anchor_uses_recorded_workspace
test_explicit_layout_modes
test_focus_never_stolen
test_invalid_layout_errors
