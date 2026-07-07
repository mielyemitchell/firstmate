#!/usr/bin/env bash
# fm-send --expect-ack and fm-watch pending acknowledgement behavior.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-ack-lib.sh
. "$ROOT/bin/fm-ack-lib.sh"

SEND="$ROOT/bin/fm-send.sh"
WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-ack-loop)

make_send_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    target=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -n "${FM_FAKE_TMUX_DEAD_TARGET:-}" ] && [ "$target" = "$FM_FAKE_TMUX_DEAD_TARGET" ]; then
      exit 1
    fi
    printf '%%1\n'
    exit 0 ;;
  capture-pane)
    printf '│ > │\n'
    exit 0 ;;
  send-keys)
    target= literal=0 arg=
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift; arg=${1:-}; shift ;;
        *) arg=$1; shift ;;
      esac
    done
    printf 'target=%s literal=%s arg=%s\n' "$target" "$literal" "$arg" >> "$FM_TMUX_LOG"
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"
  printf '%s\n' "$dir"
}

run_send() {  # <home> <fakebin> <log> <args...>
  local home=$1 fakebin=$2 log=$3
  shift 3
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 "$SEND" "$@"
}

scan_with_wake_queue() {  # <state> <now>
  local state=$1 now=$2
  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    # shellcheck disable=SC1090,SC1091
    . "$2"
    fm_ack_scan_pending "$3" "$4"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-ack-lib.sh" "$state" "$now"
}

test_expect_ack_records_pending_after_successful_send() {
  local dir state fakebin log pending row target sent deadline
  dir=$(make_send_case record); state="$dir/state"; fakebin="$dir/fakebin"; log="$dir/tmux.log"
  : > "$log"
  fm_write_meta "$state/lane-a.meta" "window=sess:fm-lane-a" "kind=ship"

  run_send "$dir" "$fakebin" "$log" --expect-ack 3 fm-lane-a "check this now" >/dev/null 2>/dev/null \
    || fail "send with --expect-ack should succeed"
  pending="$state/.pending-acks"
  [ -s "$pending" ] || fail "successful expect-ack send did not record a pending ack"
  row=$(cat "$pending")
  target=$(printf '%s' "$row" | cut -f1)
  sent=$(printf '%s' "$row" | cut -f2)
  deadline=$(printf '%s' "$row" | cut -f3)
  [ "$target" = lane-a ] || fail "pending ack stored wrong target id: $target"
  [ "$deadline" -eq "$((sent + 180))" ] || fail "deadline was not sent_at + minutes*60"
  assert_contains "$row" "check this now" "pending ack should keep a short message summary"
  assert_contains "$(cat "$log")" "target=sess:fm-lane-a literal=1 arg=check this now" "send should still type message"
  pass "fm-send --expect-ack records target, deadline, baseline, and summary after a successful lane send"
}

test_raw_pane_rejected_with_expect_ack() {
  local dir fakebin log err rc
  dir=$(make_send_case raw-pane); fakebin="$dir/fakebin"; log="$dir/tmux.log"; err="$dir/send.err"
  : > "$log"

  run_send "$dir" "$fakebin" "$log" --expect-ack 1 sess:raw-pane "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "raw pane with --expect-ack should fail"
  assert_contains "$(cat "$err")" "cannot expect-ack a raw pane" "raw pane rejection should be explicit"
  [ ! -s "$dir/state/.pending-acks" ] || fail "raw pane rejection recorded a pending ack"
  pass "fm-send --expect-ack rejects explicit backend pane targets"
}

test_ack_satisfied_by_status_change_clears_pending() {
  local dir state
  dir=$(make_case ack-satisfied); state="$dir/state"
  printf 'working: old\n' > "$state/task.status"
  fm_ack_record "$state" task 100 160 "$(fm_ack_stat_sig "$state/task.status")" "$(fm_ack_line_count "$state/task.status")" "captain dispatch"
  printf 'working: old\nworking: acked\n' > "$state/task.status"

  if out=$(fm_ack_scan_pending "$state" 170); then
    fail "ack-satisfied scan should not escalate: $out"
  fi
  [ ! -e "$state/.pending-acks" ] || fail "ack-satisfied scan did not clear the pending row"
  pass "pending ack clears when the target status file changes after send"
}

test_missed_ack_escalates_once() {
  local dir state out1 out2 drain_out rows
  dir=$(make_case ack-missed); state="$dir/state"; drain_out="$dir/drain.out"
  fm_ack_record "$state" stuck 100 160 - 0 "lost dispatch"

  out1=$(scan_with_wake_queue "$state" 190) || fail "missed ack should escalate"
  assert_contains "$out1" "ack-missed: fm-stuck" "missed ack reason should name target"
  assert_contains "$out1" "30s late" "missed ack reason should include lateness"
  out2=$(scan_with_wake_queue "$state" 220 || true)
  [ -z "$out2" ] || fail "missed ack escalated more than once: $out2"
  rows=$(wc -l < "$state/.pending-acks" | tr -d '[:space:]')
  [ "$rows" = 1 ] || fail "escalated ack row should remain marked, not duplicate"
  cut -f6 "$state/.pending-acks" | grep -Fx 1 >/dev/null || fail "missed ack row was not marked escalated"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after ack miss failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "ack-missed: fm-stuck" >/dev/null \
    || fail "missed ack was not queued on the normal wake path"
  pass "missed pending ack escalates once and is queued through the wake queue"
}

test_watch_surfaces_missed_ack() {
  local dir state fakebin out pid
  dir=$(make_case watch-ack-missed); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  fm_ack_record "$state" target 100 101 - 0 "watch dispatch"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface the missed ack"
  grep -F "ack-missed: fm-target" "$out" >/dev/null || fail "watcher output did not include ack-missed reason"
  pass "fm-watch surfaces expired pending acks as actionable wake reasons"
}

test_deadline_late_label_math() {
  [ "$(fm_ack_late_label 0)" = 0s ] || fail "0-second late label wrong"
  [ "$(fm_ack_late_label 59)" = 59s ] || fail "sub-minute late label wrong"
  [ "$(fm_ack_late_label 125)" = 2m5s ] || fail "minute late label wrong"
  pass "deadline lateness labels use seconds under two minutes and m/s after that"
}

test_expect_ack_records_pending_after_successful_send
test_raw_pane_rejected_with_expect_ack
test_ack_satisfied_by_status_change_clears_pending
test_missed_ack_escalates_once
test_watch_surfaces_missed_ack
test_deadline_late_label_math
