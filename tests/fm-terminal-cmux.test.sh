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

# Run fm_terminal_cmux_place_worker from the lib with STATE/cmux stub wired up.
place() {  # <workspace> <caller_surface> <layout> <exclude-id>
  STATE="$STATE_DIR" PATH="$FAKEBIN:$PATH" CMUX_FAKE_LOG="$LOG" \
    bash -c '. "$1"; shift; fm_terminal_cmux_place_worker "$@"' _ "$ROOT/bin/fm-terminal-lib.sh" "$@"
}

test_auto_splits_1_to_3_then_tab_overflow() {
  # 1st worker (0 existing) -> visible split
  seed_cmux_workers 0; : > "$LOG"
  place workspace:1 surface:1 auto newtask >/dev/null || fail "auto placement failed at N=0"
  assert_grep 'new-split right --workspace workspace:1 --surface surface:1 --focus false' "$LOG" "auto 1st worker was not a split"
  assert_no_grep 'new-surface' "$LOG" "auto 1st worker overflowed to a tab"
  # 2nd and 3rd workers -> still splits
  seed_cmux_workers 1; : > "$LOG"; place workspace:1 surface:1 auto newtask >/dev/null
  assert_grep 'new-split right' "$LOG" "auto 2nd worker was not a split"
  seed_cmux_workers 2; : > "$LOG"; place workspace:1 surface:1 auto newtask >/dev/null
  assert_grep 'new-split right' "$LOG" "auto 3rd worker was not a split"
  # 4th worker (3 existing) -> tab overflow into the crew pane
  seed_cmux_workers 3; : > "$LOG"; place workspace:1 surface:1 auto newtask >/dev/null
  assert_grep 'new-surface --type terminal --pane pane:9 --workspace workspace:1 --focus false' "$LOG" "auto 4th worker did not overflow to a tab in the crew pane"
  assert_no_grep 'new-split' "$LOG" "auto 4th worker created a split instead of overflowing"
  pass "auto layout: splits for workers 1-3, tab overflow for the 4th"
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
  # every placement shape must pass --focus false
  seed_cmux_workers 0; : > "$LOG"; place workspace:1 surface:1 auto newtask >/dev/null
  assert_grep '--focus false' "$LOG" "split placement did not pass --focus false"
  seed_cmux_workers 3; : > "$LOG"; place workspace:1 surface:1 auto newtask >/dev/null
  assert_grep '--focus false' "$LOG" "tab placement did not pass --focus false"
  # no caller surface -> new-pane fallback, still --focus false
  seed_cmux_workers 0; : > "$LOG"; place workspace:1 '' auto newtask >/dev/null
  assert_grep 'new-pane --type terminal --direction right --workspace workspace:1 --focus false' "$LOG" "empty caller surface did not fall back to new-pane"
  pass "placement never steals focus (--focus false on split, tab, and pane)"
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
test_auto_splits_1_to_3_then_tab_overflow
test_explicit_layout_modes
test_focus_never_stolen
test_invalid_layout_errors
