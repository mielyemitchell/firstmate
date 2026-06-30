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

test_peek_uses_cmux_read_screen
test_send_uses_cmux_send_and_newline
test_send_key_maps_ctrl_c
