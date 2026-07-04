#!/usr/bin/env bash
# Tests for bin/fm-restart.sh's secondmate-only restart flow.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-restart-tests)

make_restart_root() {  # <case-dir>
  local dir=$1 root="$1/root" bin="$1/root/bin"
  mkdir -p "$bin"
  cp "$ROOT/bin/fm-restart.sh" "$bin/fm-restart.sh"
  chmod +x "$bin/fm-restart.sh"
  ln -s "$ROOT/bin/fm-backend.sh" "$bin/fm-backend.sh"
  ln -s "$ROOT/bin/fm-tmux-lib.sh" "$bin/fm-tmux-lib.sh"
  ln -s "$ROOT/bin/backends" "$bin/backends"
  cat > "$bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf 'send:%s:%s\n' "${1:-}" "${2:-}" >> "$FM_RESTART_LOG"
case "${1:-}:${2:-}" in
  fm-lane:Stow*) ;;
  *:/quit|*:/exit)
    printf 'zsh\n' > "$FM_FAKE_COMMAND_FILE"
    printf 'zsh\n' > "$FM_FAKE_PROCESS_ARGV_FILE"
    ;;
esac
exit 0
SH
  cat > "$bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf 'spawn:%s\n' "$*" >> "$FM_RESTART_LOG"
exit 0
SH
  chmod +x "$bin/fm-guard.sh" "$bin/fm-send.sh" "$bin/fm-spawn.sh"
  printf '%s\n' "$root"
}

make_fake_tmux() {  # <case-dir>
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf 'tmux:%s\n' "$*" >> "$FM_RESTART_LOG"
case "${1:-}" in
  display-message)
    if [ "$(cat "$FM_FAKE_EXISTS_FILE" 2>/dev/null || echo 1)" != 1 ]; then
      exit 1
    fi
    case "$*" in
      *pane_pid*) printf '100\n'; exit 0 ;;
      *pane_current_command*) cat "$FM_FAKE_COMMAND_FILE"; exit 0 ;;
      *pane_id*) printf '%%1\n'; exit 0 ;;
    esac
    ;;
  kill-window)
    printf '0\n' > "$FM_FAKE_EXISTS_FILE"
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fb/ps" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = -axo ]; then
  printf '100 1 Ss zsh\n'
  printf '101 100 S %s\n' "$(cat "$FM_FAKE_PROCESS_ARGV_FILE" 2>/dev/null || cat "$FM_FAKE_COMMAND_FILE")"
  exit 0
fi
exit 1
SH
  chmod +x "$fb/tmux" "$fb/ps"
  printf '%s\n' "$fb"
}

make_fake_herdr() {  # <case-dir>
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=()
for a in "$@"; do
  [ "$a" = --session ] && break
  args+=("$a")
done
printf 'herdr:%s\n' "${args[*]}" >> "$FM_RESTART_LOG"
cmd="${args[0]:-} ${args[1]:-}"
case "$cmd" in
  "status --json")
    printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
    ;;
  "pane get")
    [ "$(cat "$FM_FAKE_EXISTS_FILE" 2>/dev/null || echo 1)" = 1 ] || exit 1
    printf '{"result":{"pane":{"pane_id":"w1:p1","tab_id":"w1:t1"}}}\n'
    ;;
  "pane process-info")
    [ "$(cat "$FM_FAKE_EXISTS_FILE" 2>/dev/null || echo 1)" = 1 ] || exit 1
    cmd_name=$(cat "$FM_FAKE_COMMAND_FILE")
    printf '{"result":{"process_info":{"foreground_processes":[{"argv0":"%s","argv":["%s"]}]}}}\n' "$cmd_name" "$cmd_name"
    ;;
  "tab rename")
    printf 'label:%s\n' "${args[3]:-}" > "$FM_FAKE_LABEL_FILE"
    ;;
  "pane close")
    [ -f "$FM_FAKE_CLOSE_STICKS_FILE" ] || printf '0\n' > "$FM_FAKE_EXISTS_FILE"
    ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

new_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config"
  printf '1\n' > "$dir/exists"
  printf 'codex\n' > "$dir/command"
  printf 'codex\n' > "$dir/process-argv"
  : > "$dir/log"
  printf '%s\n' "$dir"
}

write_lane_meta() {  # <case-dir> <kind> <backend> <window>
  local dir=$1 kind=$2 backend=$3 window=$4 meta="$1/home/state/lane.meta"
  fm_write_meta "$meta" \
    "window=$window" \
    "worktree=$dir/subhome" \
    "project=$dir/subhome" \
    "harness=codex" \
    "kind=$kind" \
    "mode=secondmate" \
    "home=$dir/subhome" \
    "projects=alpha"
  [ "$backend" = tmux ] || printf 'backend=%s\n' "$backend" >> "$meta"
}

run_restart() {  # <case-dir> <root> <fakebin> [args...]
  local dir=$1 root=$2 fakebin=$3
  shift 3
  PATH="$fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$root" \
    FM_HOME="$dir/home" \
    FM_RESTART_LOG="$dir/log" \
    FM_FAKE_EXISTS_FILE="$dir/exists" \
    FM_FAKE_COMMAND_FILE="$dir/command" \
    FM_FAKE_PROCESS_ARGV_FILE="$dir/process-argv" \
    FM_FAKE_LABEL_FILE="$dir/label" \
    FM_FAKE_CLOSE_STICKS_FILE="$dir/close-sticks" \
    FM_RESTART_TIMEOUT="${FM_RESTART_TIMEOUT:-1}" \
    FM_RESTART_FORCE_TIMEOUT="${FM_RESTART_FORCE_TIMEOUT:-1}" \
    FM_RESTART_CLEANUP_TIMEOUT="${FM_RESTART_CLEANUP_TIMEOUT:-1}" \
    FM_RESTART_STOW_SETTLE="${FM_RESTART_STOW_SETTLE:-0}" \
    FM_RESTART_POLL_INTERVAL=1 \
    "$root/bin/fm-restart.sh" "$@"
}

test_refuses_non_secondmate() {
  local dir root fb out status
  dir=$(new_case non-secondmate); root=$(make_restart_root "$dir"); fb=$(make_fake_tmux "$dir")
  write_lane_meta "$dir" ship tmux firstmate:fm-lane
  out=$(run_restart "$dir" "$root" "$fb" lane 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "non-secondmate restart should fail"
  assert_contains "$out" "only secondmate lanes are restarted" "non-secondmate refusal did not explain why"
  pass "fm-restart: refuses non-secondmate ids"
}

test_dead_lane_respawns_without_nudge() {
  local dir root fb log
  dir=$(new_case dead); root=$(make_restart_root "$dir"); fb=$(make_fake_tmux "$dir")
  printf '0\n' > "$dir/exists"
  write_lane_meta "$dir" secondmate tmux firstmate:fm-lane
  run_restart "$dir" "$root" "$fb" lane >/dev/null || fail "dead lane respawn failed"
  log=$(cat "$dir/log")
  assert_contains "$log" "spawn:lane --backend tmux --secondmate" "dead lane did not respawn through fm-spawn"
  assert_not_contains "$log" "send:fm-lane" "dead lane should not be nudged"
  pass "fm-restart: dead lane respawns without nudge/wait"
}

test_refuses_unsupported_backend() {
  local dir root fb out status
  dir=$(new_case unsupported-backend); root=$(make_restart_root "$dir"); fb=$(make_fake_tmux "$dir")
  write_lane_meta "$dir" secondmate zellij firstmate:1
  out=$(run_restart "$dir" "$root" "$fb" lane 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "unsupported backend restart should fail"
  assert_contains "$out" "supports secondmate lanes on tmux/herdr only" "unsupported backend refusal did not explain the supported backends"
  assert_not_contains "$(cat "$dir/log")" "spawn:" "unsupported backend must not respawn"
  pass "fm-restart: refuses unsupported backends instead of guessing process state"
}

test_tmux_live_lane_stows_exits_kills_then_respawns() {
  local dir root fb log
  dir=$(new_case tmux-live); root=$(make_restart_root "$dir"); fb=$(make_fake_tmux "$dir")
  write_lane_meta "$dir" secondmate tmux firstmate:fm-lane
  run_restart "$dir" "$root" "$fb" lane >/dev/null || fail "tmux live restart failed"
  log=$(cat "$dir/log")
  assert_contains "$log" "send:fm-lane:Stow" "live lane was not asked to stow via marked fm-send"
  assert_not_contains "$log" "exit this agent" "marked stow nudge must not ask the agent to exit itself"
  assert_contains "$log" "send:firstmate:fm-lane:/quit" "live lane exit command was not sent unmarked to the raw target"
  assert_contains "$log" "tmux:kill-window -t firstmate:fm-lane" "tmux old window was not killed before respawn"
  assert_contains "$log" "spawn:lane --backend tmux --secondmate" "tmux lane did not respawn through fm-spawn"
  case "$log" in
    *"send:fm-lane:Stow"*$'\n'*"send:firstmate:fm-lane:/quit"*$'\n'*"tmux:kill-window -t firstmate:fm-lane"*$'\n'*"spawn:lane --backend tmux --secondmate"*) ;;
    *) fail "tmux restart order was not marked stow -> raw exit -> kill -> spawn"$'\n'"$log" ;;
  esac
  pass "fm-restart: live tmux lane stows/exits, kills old window, respawns"
}

test_tmux_node_wrapped_codex_stows_before_respawn() {
  local dir root fb log
  dir=$(new_case tmux-node-codex); root=$(make_restart_root "$dir"); fb=$(make_fake_tmux "$dir")
  printf 'node\n' > "$dir/command"
  printf 'node /opt/homebrew/bin/codex.js\n' > "$dir/process-argv"
  write_lane_meta "$dir" secondmate tmux firstmate:fm-lane
  run_restart "$dir" "$root" "$fb" lane >/dev/null || fail "tmux node-wrapped codex restart failed"
  log=$(cat "$dir/log")
  assert_contains "$log" "send:fm-lane:Stow" "node-wrapped codex lane was not recognized as the harness process"
  assert_contains "$log" "send:firstmate:fm-lane:/quit" "node-wrapped codex lane exit command was not sent to raw target"
  assert_contains "$log" "spawn:lane --backend tmux --secondmate" "node-wrapped codex lane did not respawn"
  pass "fm-restart: tmux detects node-wrapped codex from pane process argv"
}

test_herdr_live_lane_renames_spawns_then_closes_old_tab() {
  local dir root fb log
  dir=$(new_case herdr-live); root=$(make_restart_root "$dir"); fb=$(make_fake_herdr "$dir")
  write_lane_meta "$dir" secondmate herdr herdrtest:w1:p1
  run_restart "$dir" "$root" "$fb" lane >/dev/null || fail "herdr live restart failed"
  log=$(cat "$dir/log")
  assert_contains "$log" "send:fm-lane:Stow" "herdr lane was not asked to stow and exit"
  assert_contains "$log" "send:herdrtest:w1:p1:/quit" "herdr lane exit command was not sent unmarked to the raw target"
  assert_contains "$log" "herdr:tab rename w1:t1 old-fm-lane-" "herdr old tab was not renamed out of fm-lane"
  assert_contains "$log" "spawn:lane --backend herdr --secondmate" "herdr lane did not respawn through fm-spawn"
  assert_contains "$log" "herdr:pane close w1:p1" "herdr old pane was not closed after respawn"
  case "$log" in
    *"send:fm-lane:Stow"*$'\n'*"send:herdrtest:w1:p1:/quit"*$'\n'*"herdr:tab rename w1:t1 old-fm-lane-"*$'\n'*"spawn:lane --backend herdr --secondmate"*$'\n'*"herdr:pane close w1:p1"*) ;;
    *) fail "herdr restart order was not marked stow -> raw exit -> rename -> spawn -> close"$'\n'"$log" ;;
  esac
  pass "fm-restart: live herdr lane renames old tab, respawns, then closes old tab"
}

test_herdr_cleanup_failure_refuses_success() {
  local dir root fb out status
  dir=$(new_case herdr-close-sticks); root=$(make_restart_root "$dir"); fb=$(make_fake_herdr "$dir")
  touch "$dir/close-sticks"
  write_lane_meta "$dir" secondmate herdr herdrtest:w1:p1
  FM_RESTART_CLEANUP_TIMEOUT=0 out=$(run_restart "$dir" "$root" "$fb" lane 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "herdr restart should fail when the old pane remains after cleanup"
  assert_contains "$out" "old herdr endpoint herdrtest:w1:p1 for lane still exists after cleanup" "herdr cleanup failure did not surface manual cleanup"
  assert_contains "$(cat "$dir/log")" "spawn:lane --backend herdr --secondmate" "herdr cleanup check should happen after replacement spawn"
  assert_not_contains "$out" "restart: lane refreshed" "herdr cleanup failure must not report refreshed"
  pass "fm-restart: herdr cleanup verifies the old endpoint is gone before success"
}

test_timeout_aborts_without_force() {
  local dir root fb out status
  dir=$(new_case timeout); root=$(make_restart_root "$dir"); fb=$(make_fake_tmux "$dir")
  cat > "$root/bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf 'send:%s:%s\n' "${1:-}" "${2:-}" >> "$FM_RESTART_LOG"
exit 0
SH
  chmod +x "$root/bin/fm-send.sh"
  write_lane_meta "$dir" secondmate tmux firstmate:fm-lane
  FM_RESTART_TIMEOUT=0 out=$(run_restart "$dir" "$root" "$fb" lane 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "timeout without force should fail"
  assert_contains "$out" "rerun with --force" "timeout did not explain --force recovery"
  assert_not_contains "$(cat "$dir/log")" "spawn:" "timeout without force must not respawn"
  pass "fm-restart: timeout aborts honestly without --force"
}

test_force_uses_exit_sequence_then_respawns() {
  local dir root fb log
  dir=$(new_case force); root=$(make_restart_root "$dir"); fb=$(make_fake_tmux "$dir")
  cat > "$root/bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf 'send:%s:%s\n' "${1:-}" "${2:-}" >> "$FM_RESTART_LOG"
exit 0
SH
  chmod +x "$root/bin/fm-send.sh"
  write_lane_meta "$dir" secondmate tmux firstmate:fm-lane
  FM_RESTART_TIMEOUT=0 FM_RESTART_FORCE_TIMEOUT=0 run_restart "$dir" "$root" "$fb" --force lane >/dev/null \
    || fail "forced restart failed"
  log=$(cat "$dir/log")
  assert_contains "$log" "send:firstmate:fm-lane:--key" "force did not send an interrupt key through fm-send"
  assert_contains "$log" "send:firstmate:fm-lane:/quit" "codex force did not send /quit to the explicit backend target"
  assert_contains "$log" "tmux:kill-window -t firstmate:fm-lane" "force did not close old endpoint"
  assert_contains "$log" "spawn:lane --backend tmux --secondmate" "force did not respawn"
  pass "fm-restart: --force uses harness exit sequence, then closes and respawns"
}

test_refuses_non_secondmate
test_dead_lane_respawns_without_nudge
test_refuses_unsupported_backend
test_tmux_live_lane_stows_exits_kills_then_respawns
test_tmux_node_wrapped_codex_stows_before_respawn
test_herdr_live_lane_renames_spawns_then_closes_old_tab
test_herdr_cleanup_failure_refuses_success
test_timeout_aborts_without_force
test_force_uses_exit_sequence_then_respawns
