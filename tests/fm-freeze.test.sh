#!/usr/bin/env bash
# tests/fm-freeze.test.sh - fleet freeze toggling and command refusal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FREEZE="$ROOT/bin/fm-freeze.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
SEND="$ROOT/bin/fm-send.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-freeze-tests)

new_home() {
  local name=$1 home
  home="$TMP_ROOT/$name/home"
  mkdir -p "$home/state" "$home/data" "$home/projects"
  printf '%s\n' "$home"
}

test_freeze_on_status_off() {
  local home out
  home=$(new_home toggle)

  out=$(FM_HOME="$home" "$FREEZE" on "incident review")
  assert_contains "$out" "fleet frozen:" "freeze on did not report frozen"
  [ -f "$home/state/.fleet-freeze" ] || fail "freeze file was not written"
  assert_contains "$(cat "$home/state/.fleet-freeze")" "reason=incident review" "freeze reason missing"

  out=$(FM_HOME="$home" "$FREEZE" status)
  assert_contains "$out" "fleet frozen:" "freeze status did not report frozen"
  assert_contains "$out" "reason=incident review" "freeze status did not print reason"

  out=$(FM_HOME="$home" "$FREEZE" off)
  assert_contains "$out" "fleet unfrozen" "freeze off did not report unfrozen"
  [ ! -f "$home/state/.fleet-freeze" ] || fail "freeze file was not removed"

  pass "fm-freeze.sh toggles local fleet freeze state"
}

test_spawn_refuses_while_frozen() {
  local home out status
  home=$(new_home spawn-refuse)
  FM_HOME="$home" "$FREEZE" on "parked" >/dev/null

  status=0
  out=$(FM_HOME="$home" FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 "$SPAWN" blocked-task projects/none codex 2>&1) || status=$?

  expect_code 1 "$status" "frozen spawn should exit 1"
  assert_contains "$out" "fleet frozen: spawn refused" "spawn did not refuse because of freeze"
  assert_not_contains "$out" "no brief" "spawn continued past freeze to normal task validation"

  pass "fm-spawn.sh refuses while fleet freeze is active"
}

test_send_refuses_while_frozen() {
  local home out status
  home=$(new_home send-refuse)
  FM_HOME="$home" "$FREEZE" on "parked" >/dev/null

  status=0
  out=$(FM_HOME="$home" "$SEND" "sess:win" "hello" 2>&1) || status=$?

  expect_code 1 "$status" "frozen send should exit 1"
  assert_contains "$out" "fleet frozen: send refused" "send did not refuse because of freeze"

  pass "fm-send.sh refuses while fleet freeze is active"
}

test_watch_refuses_while_frozen() {
  local home out status
  home=$(new_home watch-refuse)
  FM_HOME="$home" "$FREEZE" on "parked" >/dev/null

  status=0
  out=$(FM_HOME="$home" "$WATCH" 2>&1) || status=$?

  expect_code 1 "$status" "frozen watcher should exit 1"
  assert_contains "$out" "fleet frozen: watch refused" "watch did not refuse because of freeze"

  pass "fm-watch.sh refuses while fleet freeze is active"
}

test_spawn_bypass_is_explicit_one_command() {
  local home out status
  home=$(new_home spawn-bypass)
  FM_HOME="$home" "$FREEZE" on "parked" >/dev/null

  status=0
  out=$(FM_HOME="$home" FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 FM_FLEET_FREEZE_BYPASS=1 "$SPAWN" bypass-task projects/none codex 2>&1) || status=$?

  [ "$status" -ne 0 ] || fail "bypassed spawn with missing brief should still fail normal validation"
  assert_not_contains "$out" "fleet frozen" "explicit bypass did not bypass freeze guard"
  assert_contains "$out" "projects/none" "bypassed spawn did not reach normal task validation"

  pass "fleet freeze bypass is explicit and scoped to one command"
}

test_freeze_on_status_off
test_spawn_refuses_while_frozen
test_send_refuses_while_frozen
test_watch_refuses_while_frozen
test_spawn_bypass_is_explicit_one_command
