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
  send|send-key|close-surface|close-workspace) printf 'OK surface:2 workspace:1\n'; exit 0 ;;
  new-split|new-pane|new-surface) printf 'created surface:7 workspace:1\n'; exit 0 ;;
  new-window) echo 'new-window must not be used for cmux auto overflow' >&2; exit 99 ;;
  current-window) printf 'E566A1D2-0000-0000-0000-000000000002\n'; exit 0 ;;
  new-workspace)
    win_seen=0; win_value=
    prev=
    for arg in "$@"; do
      if [ "$prev" = "--window" ]; then win_seen=1; win_value=$arg; fi
      prev=$arg
    done
    [ "$win_seen" = 1 ] && [ -n "$win_value" ] || { echo 'missing explicit --window' >&2; exit 98; }
    printf 'created workspace:9 surface:7\n'
    exit 0
    ;;
  identify) printf '{"window":"window:2","workspace":"workspace:9","surface":"surface:7"}\n'; exit 0 ;;
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
action() { FM_CONFIG_OVERRIDE="$CONFIG_DIR" bash -c '. "$1"; fm_terminal_cmux_layout_action "$2" "$3"' _ "$ROOT/bin/fm-terminal-lib.sh" "$@"; }
slot() { FM_CONFIG_OVERRIDE="$CONFIG_DIR" bash -c '. "$1"; fm_terminal_cmux_grid_slot "$2"' _ "$ROOT/bin/fm-terminal-lib.sh" "$@"; }
capacity() { FM_CONFIG_OVERRIDE="$CONFIG_DIR" bash -c '. "$1"; fm_terminal_cmux_grid_capacity' _ "$ROOT/bin/fm-terminal-lib.sh"; }

test_layout_action_grid_and_workspace() {
  local a n
  # auto: grid within a workspace, overflow to a new workspace each time it fills (cap 4).
  for n in 0 1 2 3; do a=$(action auto "$n"); [ "$a" = grid ] || fail "auto N=$n expected grid, got '$a'"; done
  a=$(action auto 4); [ "$a" = workspace ] || fail "auto N=4 expected workspace, got '$a'"
  for n in 5 6 7; do a=$(action auto "$n"); [ "$a" = grid ] || fail "auto N=$n expected grid, got '$a'"; done
  a=$(action auto 8); [ "$a" = workspace ] || fail "auto N=8 expected workspace, got '$a'"
  # capacity is tunable: at cap 2, the boundary moves to N=2.
  a=$(FM_CMUX_GRID_CAPACITY=2 bash -c '. "$1"; fm_terminal_cmux_layout_action "$2" "$3"' _ "$ROOT/bin/fm-terminal-lib.sh" auto 2)
  [ "$a" = workspace ] || fail "auto N=2 at capacity 2 expected workspace, got '$a'"
  # splits/tabs/hybrid keep their pre-grid shapes.
  a=$(action splits 5); [ "$a" = split ] || fail "splits expected split, got '$a'"
  a=$(action tabs 0); [ "$a" = split ] || fail "tabs N=0 expected split, got '$a'"
  a=$(action tabs 1); [ "$a" = tab ] || fail "tabs N=1 expected tab, got '$a'"
  a=$(action hybrid 2); [ "$a" = split ] || fail "hybrid N=2 expected split, got '$a'"
  a=$(action hybrid 3); [ "$a" = tab ] || fail "hybrid N=3 expected tab, got '$a'"
  pass "layout_action: auto grid/workspace boundary at capacity (tunable); splits/tabs/hybrid unchanged"
}

test_grid_slot_arithmetic() {
  local s
  # First grid (2x2): right off firstmate, down off W1, right off W1, down off W3.
  s=$(slot 0); [ "$s" = 'right caller' ] || fail "slot 0 expected 'right caller', got '$s'"
  s=$(slot 1); [ "$s" = 'down 0' ] || fail "slot 1 expected 'down 0', got '$s'"
  s=$(slot 2); [ "$s" = 'right 0' ] || fail "slot 2 expected 'right 0', got '$s'"
  s=$(slot 3); [ "$s" = 'down 2' ] || fail "slot 3 expected 'down 2', got '$s'"
  # Second grid (a new workspace): anchors are GLOBAL creation indices, never caller.
  s=$(slot 5); [ "$s" = 'down 4' ] || fail "slot 5 expected 'down 4', got '$s'"
  s=$(slot 6); [ "$s" = 'right 4' ] || fail "slot 6 expected 'right 4', got '$s'"
  s=$(slot 7); [ "$s" = 'down 6' ] || fail "slot 7 expected 'down 6', got '$s'"
  pass "grid_slot: right/down alternation, caller anchor only for worker 1, global anchors across workspaces"
}

test_grid_capacity_env_config_default_precedence() {
  local c a s
  rm -f "$CONFIG_DIR/cmux-grid-capacity"
  c=$(capacity); [ "$c" = 4 ] || fail "default capacity expected 4, got '$c'"
  printf '6\n' > "$CONFIG_DIR/cmux-grid-capacity"
  c=$(capacity); [ "$c" = 6 ] || fail "config capacity expected 6, got '$c'"
  c=$(FM_CMUX_GRID_CAPACITY=5 capacity); [ "$c" = 5 ] || fail "env capacity should override config (expected 5, got '$c')"
  printf 'bogus\n' > "$CONFIG_DIR/cmux-grid-capacity"
  c=$(capacity); [ "$c" = 4 ] || fail "invalid config capacity should fall back to 4, got '$c'"
  printf '0\n' > "$CONFIG_DIR/cmux-grid-capacity"
  c=$(capacity); [ "$c" = 4 ] || fail "non-positive config capacity should fall back to 4, got '$c'"
  printf '6\n' > "$CONFIG_DIR/cmux-grid-capacity"
  a=$(action auto 5); [ "$a" = grid ] || fail "cap=6 N=5 expected grid, got '$a'"
  a=$(action auto 6); [ "$a" = workspace ] || fail "cap=6 N=6 expected workspace, got '$a'"
  s=$(FM_CMUX_GRID_ROWS=2 slot 4); [ "$s" = 'right 2' ] || fail "cap=6 rows=2 slot 4 expected 'right 2', got '$s'"
  s=$(FM_CMUX_GRID_ROWS=2 slot 5); [ "$s" = 'down 4' ] || fail "cap=6 rows=2 slot 5 expected 'down 4', got '$s'"
  rm -f "$CONFIG_DIR/cmux-grid-capacity"
  pass "grid capacity: env > config/cmux-grid-capacity > default 4; invalid falls back; cap=6 rows=2 math is column-major"
}

test_auto_grid_then_workspace_overflow() {
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
  # Worker 5 (4 existing = capacity): overflow to a NEW workspace, not a split/tab/window.
  seed_grid_workers 4; : > "$LOG"; place workspace:1 surface:5 auto newtask >/dev/null
  assert_grep 'current-window' "$LOG" "grid worker 5 did not resolve the current window explicitly"
  assert_grep 'new-workspace --name fm crew 2 --window E566A1D2-0000-0000-0000-000000000002 --focus false' "$LOG" "grid worker 5 did not overflow to a named workspace in the current window"
  assert_no_grep 'new-window' "$LOG" "grid worker 5 wrongly opened a new OS window"
  assert_no_grep 'new-split' "$LOG" "grid worker 5 wrongly created a split at capacity"
  assert_no_grep 'new-surface' "$LOG" "grid worker 5 wrongly created a tab at capacity"
  pass "auto layout: 2x2 grid (right/down/right/down off firstmate then workers), same-window workspace at capacity"
}

test_auto_overflow_workspace_shape() {
  # At capacity the overflow creates a named workspace in firstmate's current
  # window. It never passes an empty --window and never shells out to new-window.
  # It echoes both the new surface and workspace so spawn addresses the worker in
  # that overflow workspace, plus an ownership marker for teardown.
  seed_grid_workers 4; : > "$LOG"
  local out
  out=$(place workspace:1 surface:5 auto newtask) || fail "workspace overflow placement failed"
  assert_no_grep 'new-window' "$LOG" "overflow invoked forbidden cmux new-window"
  assert_grep 'current-window' "$LOG" "overflow did not explicitly resolve the current window"
  assert_grep 'new-workspace --name fm crew 2 --window E566A1D2-0000-0000-0000-000000000002 --focus false' "$LOG" "overflow did not target the resolved current window with focus disabled"
  assert_no_grep ' --window  ' "$LOG" "overflow passed an empty --window"
  assert_contains "$out" 'surface:7' "workspace placement did not echo the worker surface"
  assert_contains "$out" 'workspace:9' "workspace placement did not echo the overflow workspace"
  assert_contains "$out" 'owned_workspace=1' "workspace placement did not echo the owned workspace marker"
  pass "auto overflow: named same-window workspace using explicit current-window, echoing surface + workspace + ownership"
}

test_grid_anchor_uses_recorded_workspace() {
  # A worker that lives in an overflow workspace records its own workspace. When a later
  # worker tiles beside it, the split must be addressed in THAT workspace, not
  # firstmate's, so grid tiling is correct across workspaces.
  rm -f "$STATE_DIR"/*.meta; : > "$LOG"
  local i=1
  while [ "$i" -le 4 ]; do
    fm_write_meta "$STATE_DIR/gw-$i.meta" 'terminal_backend=cmux' "surface=surface:$((10 + i))" 'workspace=workspace:1' 'kind=ship'
    i=$((i + 1))
  done
  # Worker 5 lives in the overflow workspace:9.
  fm_write_meta "$STATE_DIR/gw-5.meta" 'terminal_backend=cmux' 'surface=surface:15' 'workspace=workspace:9' 'kind=ship'
  # Worker 6 (5 existing): grid_slot(5) = 'down 4' -> split down off worker 5,
  # addressed in worker 5's own workspace (workspace:9).
  place workspace:1 surface:5 auto newtask >/dev/null
  assert_grep 'new-split down --workspace workspace:9 --surface surface:15 --focus false' "$LOG" "second-workspace grid did not anchor in the prior worker's recorded workspace"
  pass "grid anchors off the prior worker's own recorded workspace (correct across workspaces)"
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
  # workspace overflow: new-workspace explicitly targets firstmate's current window
  # and passes --focus false.
  seed_grid_workers 4; : > "$LOG"; place workspace:1 surface:5 auto newtask >/dev/null
  assert_grep 'new-workspace --name fm crew 2 --window E566A1D2-0000-0000-0000-000000000002 --focus false' "$LOG" "workspace overflow did not pass --focus false"
  assert_no_grep 'new-window' "$LOG" "workspace overflow invoked forbidden new-window"
  # tab overflow (explicit tabs layout) passes --focus false
  seed_cmux_workers 1; : > "$LOG"; place workspace:1 surface:1 tabs newtask >/dev/null
  assert_grep '--focus false' "$LOG" "tab placement did not pass --focus false"
  # no caller surface -> new-pane fallback, still --focus false
  seed_grid_workers 0; : > "$LOG"; place workspace:1 '' auto newtask >/dev/null
  assert_grep 'new-pane --type terminal --direction right --workspace workspace:1 --focus false' "$LOG" "empty caller surface did not fall back to new-pane"
  pass "placement never steals focus (--focus false on grid splits, workspace overflow, tab, and fallback pane)"
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

test_spawn_source_records_owned_workspace_marker() {
  grep -F 'grep '\''^owned_workspace=1$'\''' "$ROOT/bin/fm-spawn.sh" >/dev/null \
    || fail "fm-spawn does not detect owned_workspace=1 from placement output"
  grep -F 'echo "owned_workspace=1"' "$ROOT/bin/fm-spawn.sh" >/dev/null \
    || fail "fm-spawn does not record owned_workspace=1 in meta"
  pass "spawn records the owned workspace marker emitted by overflow placement"
}

# --- cmux teardown workspace cleanup ---------------------------------------

make_teardown_root() {  # <case> <id> <marker:yes|no> <shared:yes|no>
  local name=$1 id=$2 marker=$3 shared=$4 fake
  fake="$TMP_ROOT/$name"
  mkdir -p "$fake/bin" "$fake/state" "$fake/config" "$fake/fakebin"
  ln -s "$ROOT/bin/fm-teardown.sh" "$fake/bin/fm-teardown.sh"
  ln -s "$ROOT/bin/fm-terminal-lib.sh" "$fake/bin/fm-terminal-lib.sh"
  ln -s "$ROOT/bin/fm-tmux-lib.sh" "$fake/bin/fm-tmux-lib.sh"
  cat > "$fake/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-guard.sh"
  cat > "$fake/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-fleet-sync.sh"
  cat > "$fake/bin/fm-tasks-axi-lib.sh" <<'SH'
fm_tasks_axi_backend_available() { return 1; }
SH
  cat > "$fake/fakebin/cmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CMUX_FAKE_LOG"
case "$1" in
  close-surface) printf 'OK closed surface\n'; exit 0 ;;
  close-workspace)
    if [ "${CMUX_CLOSE_WORKSPACE_FAIL:-}" = 1 ]; then
      echo 'simulated close-workspace failure' >&2
      exit 42
    fi
    printf 'OK closed workspace\n'
    exit 0
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fake/fakebin/cmux"
  fm_write_meta "$fake/state/$id.meta" \
    'terminal_backend=cmux' \
    'workspace=workspace:9' \
    'surface=surface:7' \
    "worktree=$fake/nonexistent-wt" \
    "project=$fake/nonexistent-project" \
    'harness=pi' \
    'kind=ship' \
    'mode=local-only'
  if [ "$marker" = yes ]; then
    printf '%s\n' 'owned_workspace=1' >> "$fake/state/$id.meta"
  fi
  if [ "$shared" = yes ]; then
    fm_write_meta "$fake/state/other.meta" \
      'terminal_backend=cmux' \
      'workspace=workspace:9' \
      'surface=surface:8' \
      'harness=pi' \
      'kind=ship' \
      'mode=local-only'
  fi
  printf '%s\n' "$fake"
}

run_teardown_case() {  # <fake-root> <id> [stderr-file]
  local fake=$1 id=$2 err=${3:-/dev/null}
  PATH="$fake/fakebin:$PATH" CMUX_FAKE_LOG="$LOG" CMUX_CLOSE_WORKSPACE_FAIL="${CMUX_CLOSE_WORKSPACE_FAIL:-}" FM_HOME="$fake" FM_STATE_OVERRIDE="$fake/state" FM_CONFIG_OVERRIDE="$fake/config" \
    bash "$fake/bin/fm-teardown.sh" "$id" >"$fake/out" 2>"$err"
}

test_teardown_closes_owned_unshared_workspace() {
  local fake
  fake=$(make_teardown_root td-owned-close task-owned yes no)
  : > "$LOG"
  run_teardown_case "$fake" task-owned || fail "teardown failed for owned unshared workspace"
  assert_grep 'close-surface --workspace workspace:9 --surface surface:7' "$LOG" "teardown did not close the worker surface"
  assert_grep 'close-workspace --workspace workspace:9' "$LOG" "teardown did not close an owned unshared workspace"
  pass "teardown closes an owned overflow workspace when no other live meta references it"
}

test_teardown_does_not_close_unmarked_workspace() {
  local fake
  fake=$(make_teardown_root td-unmarked task-unmarked no no)
  : > "$LOG"
  run_teardown_case "$fake" task-unmarked || fail "teardown failed for unmarked workspace"
  assert_grep 'close-surface --workspace workspace:9 --surface surface:7' "$LOG" "teardown did not close the worker surface"
  assert_no_grep 'close-workspace --workspace workspace:9' "$LOG" "teardown closed an unmarked workspace"
  pass "teardown never closes a workspace without owned_workspace=1"
}

test_teardown_does_not_close_shared_owned_workspace() {
  local fake
  fake=$(make_teardown_root td-shared task-shared yes yes)
  : > "$LOG"
  run_teardown_case "$fake" task-shared || fail "teardown failed for shared owned workspace"
  assert_grep 'close-surface --workspace workspace:9 --surface surface:7' "$LOG" "teardown did not close the worker surface"
  assert_no_grep 'close-workspace --workspace workspace:9' "$LOG" "teardown closed a workspace still referenced by another live meta"
  pass "teardown keeps an owned workspace open while another live task references it"
}

test_teardown_workspace_close_failure_is_nonfatal() {
  local fake err
  fake=$(make_teardown_root td-close-fail task-close-fail yes no)
  err="$fake/err"
  : > "$LOG"
  CMUX_CLOSE_WORKSPACE_FAIL=1 run_teardown_case "$fake" task-close-fail "$err" \
    || fail "teardown failed when close-workspace failed nonfatally"
  assert_grep 'close-workspace --workspace workspace:9' "$LOG" "teardown did not attempt to close the owned workspace"
  assert_grep 'leftover workspace remains' "$err" "teardown did not report the leftover workspace after close-workspace failed"
  pass "teardown reports close-workspace failure but completes cleanup"
}

test_peek_uses_cmux_read_screen
test_send_uses_cmux_send_and_newline
test_send_key_maps_ctrl_c
test_layout_action_grid_and_workspace
test_grid_slot_arithmetic
test_grid_capacity_env_config_default_precedence
test_auto_grid_then_workspace_overflow
test_auto_overflow_workspace_shape
test_grid_anchor_uses_recorded_workspace
test_explicit_layout_modes
test_focus_never_stolen
test_invalid_layout_errors
test_spawn_source_records_owned_workspace_marker
test_teardown_closes_owned_unshared_workspace
test_teardown_does_not_close_unmarked_workspace
test_teardown_does_not_close_shared_owned_workspace
test_teardown_workspace_close_failure_is_nonfatal
