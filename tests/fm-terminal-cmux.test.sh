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
# firstmate caller surface. By default they record the owned crew workspace used
# by the first auto grid. Pass "none" to omit workspace and exercise the safe
# missing-anchor fallback. Clears prior worker metas first.
seed_grid_workers() {  # <count> [workspace|none]
  local count=$1 workspace=${2:-workspace:9} i=1
  rm -f "$STATE_DIR"/*.meta
  while [ "$i" -le "$count" ]; do
    if [ "$workspace" = none ]; then
      fm_write_meta "$STATE_DIR/gw-$i.meta" \
        'terminal_backend=cmux' \
        "surface=surface:$((10 + i))" \
        'kind=ship'
    else
      fm_write_meta "$STATE_DIR/gw-$i.meta" \
        'terminal_backend=cmux' \
        "surface=surface:$((10 + i))" \
        "workspace=$workspace" \
        'kind=ship'
    fi
    i=$((i + 1))
  done
}

# Run fm_terminal_cmux_place_worker from the lib with STATE/cmux stub wired up.
place() {  # <workspace> <caller_surface> <layout> <exclude-id>
  STATE="$STATE_DIR" PATH="$FAKEBIN:$PATH" CMUX_FAKE_LOG="$LOG" \
    bash -c '. "$1"; shift; fm_terminal_cmux_place_worker "$@"' _ "$ROOT/bin/fm-terminal-lib.sh" "$@"
}

assert_auto_never_targets_caller() {
  assert_no_grep '--workspace workspace:1' "$LOG" "auto placement targeted the caller workspace"
  assert_no_grep '--surface surface:5' "$LOG" "auto placement split off the caller surface"
  assert_no_grep 'new-pane --type terminal' "$LOG" "auto placement fell back to a caller workspace pane"
}

# Run a pure lib function (no cmux) for the arithmetic unit tests.
action() { FM_CONFIG_OVERRIDE="$CONFIG_DIR" bash -c '. "$1"; fm_terminal_cmux_layout_action "$2" "$3"' _ "$ROOT/bin/fm-terminal-lib.sh" "$@"; }
slot() { FM_CONFIG_OVERRIDE="$CONFIG_DIR" bash -c '. "$1"; fm_terminal_cmux_grid_slot "$2"' _ "$ROOT/bin/fm-terminal-lib.sh" "$@"; }
capacity() { FM_CONFIG_OVERRIDE="$CONFIG_DIR" bash -c '. "$1"; fm_terminal_cmux_grid_capacity' _ "$ROOT/bin/fm-terminal-lib.sh"; }

test_layout_action_grid_and_workspace() {
  local a n
  # auto: every grid starts in a workspace, including the first worker (cap 4).
  a=$(action auto 0); [ "$a" = workspace ] || fail "auto N=0 expected workspace, got '$a'"
  for n in 1 2 3; do a=$(action auto "$n"); [ "$a" = grid ] || fail "auto N=$n expected grid, got '$a'"; done
  a=$(action auto 4); [ "$a" = workspace ] || fail "auto N=4 expected workspace, got '$a'"
  for n in 5 6 7; do a=$(action auto "$n"); [ "$a" = grid ] || fail "auto N=$n expected grid, got '$a'"; done
  a=$(action auto 8); [ "$a" = workspace ] || fail "auto N=8 expected workspace, got '$a'"
  # capacity is tunable: at cap 2, the boundary moves to N=2.
  a=$(FM_CMUX_GRID_CAPACITY=2 bash -c '. "$1"; fm_terminal_cmux_layout_action "$2" "$3"' _ "$ROOT/bin/fm-terminal-lib.sh" auto 0)
  [ "$a" = workspace ] || fail "auto N=0 at capacity 2 expected workspace, got '$a'"
  a=$(FM_CMUX_GRID_CAPACITY=2 bash -c '. "$1"; fm_terminal_cmux_layout_action "$2" "$3"' _ "$ROOT/bin/fm-terminal-lib.sh" auto 2)
  [ "$a" = workspace ] || fail "auto N=2 at capacity 2 expected workspace, got '$a'"
  # splits/tabs/hybrid keep their pre-grid shapes.
  a=$(action splits 5); [ "$a" = split ] || fail "splits expected split, got '$a'"
  a=$(action tabs 0); [ "$a" = split ] || fail "tabs N=0 expected split, got '$a'"
  a=$(action tabs 1); [ "$a" = tab ] || fail "tabs N=1 expected tab, got '$a'"
  a=$(action hybrid 2); [ "$a" = split ] || fail "hybrid N=2 expected split, got '$a'"
  a=$(action hybrid 3); [ "$a" = tab ] || fail "hybrid N=3 expected tab, got '$a'"
  pass "layout_action: auto starts every grid in an owned workspace; splits/tabs/hybrid unchanged"
}

test_grid_slot_arithmetic() {
  local s
  # First grid arithmetic (2x2): the caller case remains defensive, but auto
  # placement now starts worker 1 with a workspace so slot 0 is not used there.
  s=$(slot 0); [ "$s" = 'right caller' ] || fail "slot 0 expected 'right caller', got '$s'"
  s=$(slot 1); [ "$s" = 'down 0' ] || fail "slot 1 expected 'down 0', got '$s'"
  s=$(slot 2); [ "$s" = 'right 0' ] || fail "slot 2 expected 'right 0', got '$s'"
  s=$(slot 3); [ "$s" = 'down 2' ] || fail "slot 3 expected 'down 2', got '$s'"
  # Second grid (a new workspace): anchors are GLOBAL creation indices, never caller.
  s=$(slot 5); [ "$s" = 'down 4' ] || fail "slot 5 expected 'down 4', got '$s'"
  s=$(slot 6); [ "$s" = 'right 4' ] || fail "slot 6 expected 'right 4', got '$s'"
  s=$(slot 7); [ "$s" = 'down 6' ] || fail "slot 7 expected 'down 6', got '$s'"
  pass "grid_slot: right/down alternation with global anchors across workspaces"
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
  # Worker 1 (0 existing): create the owned first crew workspace.
  seed_grid_workers 0; : > "$LOG"
  out=$(place workspace:1 surface:5 auto newtask) || fail "auto workspace placement failed at N=0"
  assert_grep 'current-window' "$LOG" "grid worker 1 did not resolve the current window explicitly"
  assert_grep 'new-workspace --name fm crew 1 --window E566A1D2-0000-0000-0000-000000000002 --focus false' "$LOG" "grid worker 1 did not create the first named crew workspace"
  assert_contains "$out" 'workspace:9' "first crew workspace placement did not echo the workspace"
  assert_contains "$out" 'owned_workspace=1' "first crew workspace placement did not echo ownership"
  assert_auto_never_targets_caller
  assert_no_grep 'new-window' "$LOG" "grid worker 1 wrongly opened a new window"
  assert_no_grep 'new-surface' "$LOG" "grid worker 1 overflowed to a tab"
  # Worker 2 (1 existing): split DOWN off worker 1 (surface:11) -> bottom of column 1.
  seed_grid_workers 1; : > "$LOG"; place workspace:1 surface:5 auto newtask >/dev/null
  assert_grep 'new-split down --workspace workspace:9 --surface surface:11 --focus false' "$LOG" "grid worker 2 did not split down off worker 1 inside the crew workspace"
  assert_auto_never_targets_caller
  # Worker 3 (2 existing): split RIGHT off worker 1 (surface:11) -> top of column 2.
  seed_grid_workers 2; : > "$LOG"; place workspace:1 surface:5 auto newtask >/dev/null
  assert_grep 'new-split right --workspace workspace:9 --surface surface:11 --focus false' "$LOG" "grid worker 3 did not split right off worker 1 inside the crew workspace"
  assert_auto_never_targets_caller
  # Worker 4 (3 existing): split DOWN off worker 3 (surface:13) -> bottom of column 2.
  seed_grid_workers 3; : > "$LOG"; place workspace:1 surface:5 auto newtask >/dev/null
  assert_grep 'new-split down --workspace workspace:9 --surface surface:13 --focus false' "$LOG" "grid worker 4 did not split down off worker 3 inside the crew workspace"
  assert_auto_never_targets_caller
  # Worker 5 (4 existing = capacity): overflow to a NEW workspace, not a split/tab/window.
  seed_grid_workers 4; : > "$LOG"; place workspace:1 surface:5 auto newtask >/dev/null
  assert_grep 'current-window' "$LOG" "grid worker 5 did not resolve the current window explicitly"
  assert_grep 'new-workspace --name fm crew 2 --window E566A1D2-0000-0000-0000-000000000002 --focus false' "$LOG" "grid worker 5 did not overflow to a named workspace in the current window"
  assert_auto_never_targets_caller
  assert_no_grep 'new-window' "$LOG" "grid worker 5 wrongly opened a new OS window"
  assert_no_grep 'new-split' "$LOG" "grid worker 5 wrongly created a split at capacity"
  assert_no_grep 'new-surface' "$LOG" "grid worker 5 wrongly created a tab at capacity"
  pass "auto layout: owned fm crew workspaces from worker 1, grid cells stay inside them"
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

test_auto_missing_anchor_starts_owned_workspace() {
  seed_grid_workers 1 none; : > "$LOG"
  local out
  out=$(place workspace:1 surface:5 auto newtask) || fail "missing-anchor auto fallback failed"
  assert_grep 'new-workspace --name fm crew 1 --window E566A1D2-0000-0000-0000-000000000002 --focus false' "$LOG" "missing-anchor fallback did not start an owned crew workspace"
  assert_contains "$out" 'owned_workspace=1' "missing-anchor fallback did not echo ownership"
  assert_auto_never_targets_caller
  pass "auto fallback: missing grid anchors start an owned workspace, never caller placement"
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
  # first auto worker creates an owned workspace with --focus false
  seed_grid_workers 0; : > "$LOG"; place workspace:1 surface:5 auto newtask >/dev/null
  assert_grep 'new-workspace --name fm crew 1 --window E566A1D2-0000-0000-0000-000000000002 --focus false' "$LOG" "first auto workspace placement stole focus"
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
  # forced split with no caller surface still keeps the old new-pane fallback.
  seed_cmux_workers 0; : > "$LOG"; place workspace:1 '' splits newtask >/dev/null
  assert_grep 'new-pane --type terminal --direction right --workspace workspace:1 --focus false' "$LOG" "forced split empty-caller fallback did not pass --focus false"
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

# --- cmux spawn ghost-surface repair ---------------------------------------

make_cmux_spawn_root() {  # <case>
  local name=$1 fake
  fake="$TMP_ROOT/$name"
  mkdir -p "$fake/home/state" "$fake/home/data" "$fake/home/config" "$fake/fakebin"
  printf 'cmux\n' > "$fake/home/config/terminal-backend"
  printf '%s\n' '- project [local-only] - test project (added 2026-07-02)' > "$fake/home/data/projects.md"
  fm_git_worktree "$fake/project" "$fake/wt" worker-branch
  cat > "$fake/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "treehouse $*" >> "$CMUX_FAKE_LOG"
case "$1" in
  get) printf '%s\n' "$FM_FAKE_WT" ;;
  return) printf 'returned %s\n' "${3:-}" ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fake/fakebin/treehouse"
  cat > "$fake/fakebin/cmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CMUX_FAKE_LOG"
attached() {
  [ "${CMUX_GHOST_MODE:-healthy}" = healthy ] || [ -f "$CMUX_FAKE_STATE.attached" ]
}
case "$1" in
  ping) exit 0 ;;
  identify) printf '{"caller":{"workspace_ref":"workspace:1","surface_ref":"surface:5"}}\n'; exit 0 ;;
  current-window) printf 'window:2\n'; exit 0 ;;
  current-workspace) printf 'workspace:1\n'; exit 0 ;;
  new-workspace) printf 'created workspace:9 surface:7\n'; exit 0 ;;
  list-panes) printf 'pane:4\n'; exit 0 ;;
  list-pane-surfaces) printf 'surface:7\n'; exit 0 ;;
  rename-tab)
    # Log arg count too, so a test can confirm the title landed as ONE shell
    # argument (unsplit) rather than several word-split arguments.
    printf 'RENAME_ARGC=%s\n' "$#" >> "$CMUX_FAKE_LOG"
    exit 0
    ;;
  send|refresh-surfaces) exit 0 ;;
  read-screen)
    if attached; then printf 'codex prompt ready\n'; exit 0; fi
    printf 'Terminal surface not found\n' >&2
    exit 1
    ;;
  surface-health)
    if attached; then printf 'surface:7 in_window=true\n'; else printf 'surface:7 in_window=false\n'; fi
    exit 0
    ;;
  select-workspace)
    if [ "${3:-}" = workspace:9 ] && [ "${CMUX_GHOST_MODE:-}" != never ]; then
      : > "$CMUX_FAKE_STATE.attached"
    fi
    exit 0
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fake/fakebin/cmux"
  printf '%s\n' "$fake"
}

run_cmux_spawn_case() {  # <fake-root> <id> <healthy|ghost|never>
  local fake=$1 id=$2 mode=$3
  mkdir -p "$fake/home/data/$id"
  printf 'Read this test brief.\n' > "$fake/home/data/$id/brief.md"
  : > "$fake/cmux.log"
  rm -f "$fake/cmux-state.attached"
  PATH="$fake/fakebin:$PATH" \
    FM_HOME="$fake/home" FM_STATE_OVERRIDE="$fake/home/state" FM_DATA_OVERRIDE="$fake/home/data" FM_CONFIG_OVERRIDE="$fake/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_WT="$fake/wt" CMUX_FAKE_LOG="$fake/cmux.log" CMUX_FAKE_STATE="$fake/cmux-state" CMUX_GHOST_MODE="$mode" \
    FM_CMUX_ATTACH_PROBES=1 FM_CMUX_ATTACH_DELAY=0 FM_CMUX_GHOST_REPAIRS=2 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$fake/project" codex >"$fake/out" 2>"$fake/err"
}

cmux_log_count() {  # <pattern> <file>
  awk -v pat="$1" 'index($0, pat) { n++ } END { print n + 0 }' "$2"
}

run_cmux_spawn_case_extra() {  # <fake-root> <id> <healthy|ghost|never> [extra fm-spawn.sh args...]
  local fake=$1 id=$2 mode=$3
  shift 3
  mkdir -p "$fake/home/data/$id"
  printf 'Read this test brief.\n' > "$fake/home/data/$id/brief.md"
  : > "$fake/cmux.log"
  rm -f "$fake/cmux-state.attached"
  PATH="$fake/fakebin:$PATH" \
    FM_HOME="$fake/home" FM_STATE_OVERRIDE="$fake/home/state" FM_DATA_OVERRIDE="$fake/home/data" FM_CONFIG_OVERRIDE="$fake/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_WT="$fake/wt" CMUX_FAKE_LOG="$fake/cmux.log" CMUX_FAKE_STATE="$fake/cmux-state" CMUX_GHOST_MODE="$mode" \
    FM_CMUX_ATTACH_PROBES=1 FM_CMUX_ATTACH_DELAY=0 FM_CMUX_GHOST_REPAIRS=2 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$fake/project" codex "$@" >"$fake/out" 2>"$fake/err"
}

test_spawn_healthy_surface_skips_repair() {
  local fake sends
  fake=$(make_cmux_spawn_root spawn-healthy)
  run_cmux_spawn_case "$fake" ok-healthy healthy || fail "healthy cmux spawn failed: $(cat "$fake/err")"
  assert_present "$fake/home/state/ok-healthy.meta" "healthy spawn did not write meta"
  assert_grep 'read-screen --workspace workspace:9 --surface surface:7 --lines 1' "$fake/cmux.log" "healthy spawn did not probe the surface"
  assert_no_grep 'select-workspace --workspace workspace:9' "$fake/cmux.log" "healthy spawn ran ghost repair"
  sends=$(cmux_log_count 'send --workspace workspace:9 --surface surface:7' "$fake/cmux.log")
  [ "$sends" = 1 ] || fail "healthy spawn should send launch once, sent $sends times"
  pass "spawn probes healthy cmux surfaces without repair"
}

test_spawn_repairs_ghost_surface_and_resends_launch() {
  local fake sends target_line back_line
  fake=$(make_cmux_spawn_root spawn-ghost)
  run_cmux_spawn_case "$fake" repair-ghost ghost || fail "ghost-repair cmux spawn failed: $(cat "$fake/err")"
  assert_present "$fake/home/state/repair-ghost.meta" "repaired ghost spawn did not write meta"
  assert_grep 'select-workspace --workspace workspace:9' "$fake/cmux.log" "ghost repair did not select the worker workspace"
  assert_grep 'select-workspace --workspace workspace:1' "$fake/cmux.log" "ghost repair did not restore the original workspace"
  target_line=$(grep -n -F 'select-workspace --workspace workspace:9' "$fake/cmux.log" | head -1 | cut -d: -f1)
  back_line=$(grep -n -F 'select-workspace --workspace workspace:1' "$fake/cmux.log" | head -1 | cut -d: -f1)
  [ "$target_line" -lt "$back_line" ] || fail "ghost repair did not select target before restoring original workspace"
  sends=$(cmux_log_count 'send --workspace workspace:9 --surface surface:7' "$fake/cmux.log")
  [ "$sends" = 2 ] || fail "ghost repair should send launch twice, sent $sends times"
  pass "spawn repairs ghost cmux surfaces with select-toggle and launch resend"
}

test_spawn_fails_loudly_when_ghost_never_attaches() {
  local fake status repairs sends
  fake=$(make_cmux_spawn_root spawn-never)
  run_cmux_spawn_case "$fake" dead-ghost never; status=$?
  expect_code 1 "$status" "unrepaired ghost spawn did not fail"
  assert_absent "$fake/home/state/dead-ghost.meta" "unrepaired ghost spawn must not leave meta"
  assert_grep 'cmux surface did not attach after launch/repair; workspace=workspace:9 surface=surface:7' "$fake/err" "unrepaired ghost error did not name workspace and surface"
  repairs=$(cmux_log_count 'select-workspace --workspace workspace:9' "$fake/cmux.log")
  [ "$repairs" = 2 ] || fail "unrepaired ghost should cap repair attempts at 2, saw $repairs"
  sends=$(cmux_log_count 'send --workspace workspace:9 --surface surface:7' "$fake/cmux.log")
  [ "$sends" = 3 ] || fail "unrepaired ghost should send initial launch plus 2 repair resends, sent $sends times"
  pass "spawn fails loudly with no meta when cmux ghost repair is exhausted"
}

# --- cmux spawn plain-English tab titles ------------------------------------

test_spawn_title_renames_cmux_tab() {
  local fake
  fake=$(make_cmux_spawn_root spawn-title)
  run_cmux_spawn_case_extra "$fake" titled-ok healthy --title 'twinfield · fixing date test' \
    || fail "titled cmux spawn failed: $(cat "$fake/err")"
  assert_grep "rename-tab --workspace workspace:9 --surface surface:7 twinfield · fixing date test" "$fake/cmux.log" \
    "titled spawn did not rename the cmux tab to the exact title"
  assert_grep 'RENAME_ARGC=6' "$fake/cmux.log" "titled spawn did not pass the title as a single shell argument"
  assert_grep 'title=twinfield · fixing date test' "$fake/home/state/titled-ok.meta" "titled spawn did not record title= in meta"
  pass "spawn renames the cmux tab and records title= when --title is given"
}

test_spawn_without_title_uses_default_tab() {
  local fake
  fake=$(make_cmux_spawn_root spawn-notitle)
  run_cmux_spawn_case_extra "$fake" no-title healthy \
    || fail "untitled cmux spawn failed: $(cat "$fake/err")"
  assert_grep 'rename-tab --workspace workspace:9 --surface surface:7 fm-no-title' "$fake/cmux.log" \
    "untitled spawn did not fall back to the machine-id tab title"
  assert_no_grep 'title=' "$fake/home/state/no-title.meta" "untitled spawn should not record title= in meta"
  pass "spawn without --title keeps the machine-id tab title and records no title="
}

test_spawn_title_truncates_overlong() {
  local fake long_title truncated
  fake=$(make_cmux_spawn_root spawn-longtitle)
  long_title="nemesis-item-tracker · reconciling the par level algorithm against yesterday's stockout data across every location"
  run_cmux_spawn_case_extra "$fake" long-title healthy --title "$long_title" \
    || fail "overlong-title cmux spawn failed: $(cat "$fake/err")"
  truncated="${long_title:0:47}…"
  assert_grep "rename-tab --workspace workspace:9 --surface surface:7 $truncated" "$fake/cmux.log" \
    "overlong title was not truncated to 47 chars plus ellipsis"
  assert_grep "title=$truncated" "$fake/home/state/long-title.meta" "overlong title in meta was not truncated"
  pass "spawn truncates an overlong --title with an ellipsis and never breaks rename-tab"
}

test_spawn_title_with_apostrophe_and_spaces() {
  local fake
  fake=$(make_cmux_spawn_root spawn-apostrophe)
  run_cmux_spawn_case_extra "$fake" quote-title healthy --title "mysubo's dashboard · fixing captain's chart" \
    || fail "apostrophe-title cmux spawn failed: $(cat "$fake/err")"
  assert_grep "rename-tab --workspace workspace:9 --surface surface:7 mysubo's dashboard · fixing captain's chart" "$fake/cmux.log" \
    "title with apostrophes and spaces did not pass through safely"
  assert_grep 'RENAME_ARGC=6' "$fake/cmux.log" "apostrophe title was not passed as a single shell argument"
  pass "spawn passes a --title containing apostrophes and spaces through safely"
}

test_batch_spawn_title_refused() {
  local fake out err status
  fake=$(make_cmux_spawn_root spawn-batch-title)
  mkdir -p "$fake/home/data/batch-a"
  printf 'Read this test brief.\n' > "$fake/home/data/batch-a/brief.md"
  out="$fake/batch.out"; err="$fake/batch.err"
  PATH="$fake/fakebin:$PATH" \
    FM_HOME="$fake/home" FM_STATE_OVERRIDE="$fake/home/state" FM_DATA_OVERRIDE="$fake/home/data" FM_CONFIG_OVERRIDE="$fake/home/config" \
    FM_FAKE_WT="$fake/wt" CMUX_FAKE_LOG="$fake/cmux.log" CMUX_FAKE_STATE="$fake/cmux-state" \
    "$ROOT/bin/fm-spawn.sh" "batch-a=$fake/project" codex --title 'shared title' >"$out" 2>"$err"; status=$?
  expect_code 1 "$status" "batch spawn with --title should be refused"
  assert_grep 'title applies to a single-task spawn only' "$err" "batch --title refusal did not explain per-task scoping"
  assert_absent "$fake/home/state/batch-a.meta" "refused batch --title spawn must not leave meta"
  pass "batch id=repo dispatch refuses a shared --title with a clear error"
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
test_auto_missing_anchor_starts_owned_workspace
test_grid_anchor_uses_recorded_workspace
test_explicit_layout_modes
test_focus_never_stolen
test_invalid_layout_errors
test_spawn_source_records_owned_workspace_marker
test_spawn_healthy_surface_skips_repair
test_spawn_repairs_ghost_surface_and_resends_launch
test_spawn_fails_loudly_when_ghost_never_attaches
test_spawn_title_renames_cmux_tab
test_spawn_without_title_uses_default_tab
test_spawn_title_truncates_overlong
test_spawn_title_with_apostrophe_and_spaces
test_batch_spawn_title_refused
test_teardown_closes_owned_unshared_workspace
test_teardown_does_not_close_unmarked_workspace
test_teardown_does_not_close_shared_owned_workspace
test_teardown_workspace_close_failure_is_nonfatal
