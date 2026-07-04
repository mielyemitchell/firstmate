#!/usr/bin/env bash
# Refresh a persistent secondmate lane by asking it to stow, sending the harness
# exit command directly to the raw endpoint, waiting for the harness process to
# leave, then respawning it through fm-spawn bookkeeping.
# Usage: fm-restart.sh [--force] [--skip-stow] <secondmate-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

"$FM_ROOT/bin/fm-guard.sh" || true

usage() {
  echo "usage: fm-restart.sh [--force] [--skip-stow] <secondmate-id>" >&2
  exit 2
}

FORCE=0
SKIP_STOW=0
ID=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --skip-stow) SKIP_STOW=1 ;;
    -h|--help) usage ;;
    --*) echo "error: unknown option $1" >&2; usage ;;
    *)
      [ -z "$ID" ] || usage
      ID=$1
      ;;
  esac
  shift
done
[ -n "$ID" ] || usage

TIMEOUT=${FM_RESTART_TIMEOUT:-120}
FORCE_TIMEOUT=${FM_RESTART_FORCE_TIMEOUT:-20}
CLEANUP_TIMEOUT=${FM_RESTART_CLEANUP_TIMEOUT:-5}
STOW_TIMEOUT=${FM_RESTART_STOW_TIMEOUT:-${FM_RESTART_STOW_SETTLE:-120}}
POLL_INTERVAL=${FM_RESTART_POLL_INTERVAL:-1}
case "$TIMEOUT" in ''|*[!0-9]*) echo "error: FM_RESTART_TIMEOUT must be whole seconds" >&2; exit 2 ;; esac
case "$FORCE_TIMEOUT" in ''|*[!0-9]*) echo "error: FM_RESTART_FORCE_TIMEOUT must be whole seconds" >&2; exit 2 ;; esac
case "$CLEANUP_TIMEOUT" in ''|*[!0-9]*) echo "error: FM_RESTART_CLEANUP_TIMEOUT must be whole seconds" >&2; exit 2 ;; esac
case "$STOW_TIMEOUT" in ''|*[!0-9]*) echo "error: FM_RESTART_STOW_TIMEOUT must be whole seconds" >&2; exit 2 ;; esac

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for $ID at $META" >&2; exit 1; }
STATUS_FILE="$STATE/$ID.status"

KIND=$(fm_meta_get "$META" kind)
[ "$KIND" = secondmate ] || { echo "error: $ID is kind=${KIND:-ship}; only secondmate lanes are restarted (crewmates are torn down)" >&2; exit 1; }

T=$(fm_meta_get "$META" window)
[ -n "$T" ] || { echo "error: no window= recorded in $META" >&2; exit 1; }
BACKEND=$(fm_backend_of_meta "$META")
HARNESS=$(fm_meta_get "$META" harness)
[ -n "$HARNESS" ] || HARNESS=unknown
EXPECTED_LABEL="fm-$ID"

fm_backend_validate_spawn "$BACKEND" >/dev/null || exit 1
fm_backend_source "$BACKEND" || exit 1
case "$BACKEND" in
  tmux|herdr) ;;
  *) echo "error: fm-restart supports secondmate lanes on tmux/herdr only for now; $ID uses backend=$BACKEND" >&2; exit 1 ;;
esac

harness_command() {
  local h=$1 cmd
  cmd=${h%% *}
  cmd=${cmd##*/}
  printf '%s' "$cmd"
}

HARNESS_CMD=$(harness_command "$HARNESS")

target_exists() {
  target_exists_with_label "$EXPECTED_LABEL"
}

target_exists_with_label() {
  fm_backend_target_exists "$BACKEND" "$T" "$1" >/dev/null 2>&1
}

harness_process_state() {
  local processes cmd
  cmd=$HARNESS_CMD
  if [ -z "$cmd" ] || [ "$cmd" = unknown ]; then
    printf 'unknown'
    return 0
  fi
  processes=$(fm_backend_foreground_process "$BACKEND" "$T" "$EXPECTED_LABEL" 2>/dev/null || true)
  [ -n "$processes" ] || { printf 'unknown'; return 0; }
  if printf '%s\n' "$processes" | awk -v want="$cmd" '
    {
      for (i = 1; i <= NF; i++) {
        token = $i
        sub(/^.*\//, "", token)
        sub(/\.(cjs|mjs|js)$/, "", token)
        if (token == want) found = 1
      }
    }
    END { exit found ? 0 : 1 }
  '; then
    printf 'running'
    return 0
  fi
  printf 'not-running'
}

wait_for_exit() {  # <timeout-seconds>
  local timeout=$1 deadline now
  deadline=$(($(date +%s) + timeout))
  while :; do
    ! target_exists && return 0
    case "$(harness_process_state)" in
      not-running) return 0 ;;
      running|unknown) ;;
    esac
    now=$(date +%s)
    [ "$now" -lt "$deadline" ] || return 1
    sleep "$POLL_INTERVAL"
  done
}

wait_for_target_gone() {  # <timeout-seconds> [expected-label]
  local timeout=$1 expected_label=${2:-$EXPECTED_LABEL} deadline now
  deadline=$(($(date +%s) + timeout))
  while :; do
    ! target_exists_with_label "$expected_label" && return 0
    now=$(date +%s)
    [ "$now" -lt "$deadline" ] || return 1
    sleep "$POLL_INTERVAL"
  done
}

status_line_count() {
  [ -f "$STATUS_FILE" ] || { printf '0'; return 0; }
  wc -l < "$STATUS_FILE" | tr -d '[:space:]'
}

wait_for_stow_signal() {  # <line-offset> <timeout-seconds>
  local before=$1 timeout=$2 deadline now
  deadline=$(($(date +%s) + timeout))
  while :; do
    if [ -f "$STATUS_FILE" ] && awk -v before="$before" 'NR > before && /^stowed: restart-ready([[:space:]]|$)/ { found = 1 } END { exit found ? 0 : 1 }' "$STATUS_FILE"; then
      return 0
    fi
    now=$(date +%s)
    [ "$now" -lt "$deadline" ] || return 1
    sleep "$POLL_INTERVAL"
  done
}

send_key_best_effort() {
  target_exists || { echo "error: $ID target $T no longer belongs to $EXPECTED_LABEL; aborting before sending exit input" >&2; exit 1; }
  "$SCRIPT_DIR/fm-send.sh" "$T" --key "$1" >/dev/null 2>&1 || true
}

send_text_best_effort() {
  target_exists || { echo "error: $ID target $T no longer belongs to $EXPECTED_LABEL; aborting before sending exit input" >&2; exit 1; }
  "$SCRIPT_DIR/fm-send.sh" "$T" "$1" >/dev/null 2>&1 || true
}

force_exit_sequence() {
  case "$HARNESS_CMD" in
    claude)
      send_key_best_effort Escape
      sleep 1
      graceful_exit_sequence
      ;;
    codex)
      send_key_best_effort Escape
      sleep 1
      graceful_exit_sequence
      ;;
    opencode)
      send_key_best_effort Escape
      sleep 0.5
      send_key_best_effort Escape
      sleep 1
      graceful_exit_sequence
      ;;
    pi)
      send_key_best_effort Escape
      sleep 1
      graceful_exit_sequence
      ;;
    grok)
      send_key_best_effort C-c
      sleep 1
      graceful_exit_sequence
      ;;
    *)
      send_key_best_effort C-c
      ;;
  esac
}

graceful_exit_sequence() {
  # Use the explicit backend target ($T), not fm-<id>. A bare secondmate target
  # gets the from-firstmate marker prepended by fm-send, which turns slash
  # commands into plain chat. The agent also cannot execute harness slash
  # commands on firstmate's behalf, so firstmate must send the command itself.
  case "$HARNESS_CMD" in
    claude|opencode) send_text_best_effort /exit ;;
    codex|pi) send_text_best_effort /quit ;;
    grok)
      send_key_best_effort C-q
      sleep 0.2
      send_key_best_effort C-q
      ;;
    *) send_key_best_effort C-c ;;
  esac
}

respawn() {
  "$SCRIPT_DIR/fm-spawn.sh" "$ID" --backend "$BACKEND" --secondmate
}

cleanup_and_respawn() {
  local archived_label out rc
  case "$BACKEND" in
    herdr)
      if target_exists; then
        archived_label="old-$EXPECTED_LABEL-$(date +%s)"
        echo "restart: renaming old herdr tab to $archived_label"
        fm_backend_relabel_task "$BACKEND" "$T" "$archived_label" "$EXPECTED_LABEL" \
          || { echo "error: could not rename old herdr tab for $ID; refusing to spawn a duplicate" >&2; exit 1; }
        if out=$(respawn 2>&1); then
          printf '%s\n' "$out"
        else
          rc=$?
          fm_backend_relabel_task "$BACKEND" "$T" "$EXPECTED_LABEL" "$archived_label" >/dev/null 2>&1 || true
          printf '%s\n' "$out" >&2
          echo "error: respawn failed; old herdr tab was left in place" >&2
          exit "$rc"
        fi
        fm_backend_kill "$BACKEND" "$T" "$archived_label" >/dev/null 2>&1 || true
        if ! wait_for_target_gone "$CLEANUP_TIMEOUT" "$archived_label"; then
          echo "error: old herdr endpoint $T for $ID still exists after cleanup; close it manually before treating the lane as refreshed" >&2
          exit 1
        fi
      else
        respawn
      fi
      ;;
    *)
      if target_exists; then
        fm_backend_kill "$BACKEND" "$T" "$EXPECTED_LABEL" >/dev/null 2>&1 || true
      fi
      respawn
      ;;
  esac
}

if target_exists; then
  PROCESS_STATE=$(harness_process_state)
  if [ "$PROCESS_STATE" != running ] && [ "$SKIP_STOW" -ne 1 ]; then
    case "$PROCESS_STATE" in
      unknown)
        echo "error: $ID endpoint is live, but the $HARNESS_CMD foreground process state is unknown; aborting before stow/exit/cleanup. Rerun with --skip-stow only if the lane is already stowed or safe to restart." >&2
        ;;
      *)
        echo "error: $ID endpoint is live, but the foreground process does not match $HARNESS_CMD; aborting before stow/exit/cleanup. Rerun with --skip-stow only if the lane is already stowed or safe to restart." >&2
        ;;
    esac
    exit 1
  fi
  if [ "$SKIP_STOW" -eq 1 ]; then
    echo "restart: skipping stow confirmation for $ID, then sending raw harness exit (timeout ${TIMEOUT}s)"
  else
    before_stow=$(status_line_count)
    echo "restart: asking $ID to stow; waiting for status 'stowed: restart-ready' (timeout ${STOW_TIMEOUT}s)"
    "$SCRIPT_DIR/fm-send.sh" "fm-$ID" "Stow any lane-local durable context now. Do not start new work; firstmate will refresh this lane. When stow is complete, append exactly 'stowed: restart-ready' to your status." >/dev/null
    if ! wait_for_stow_signal "$before_stow" "$STOW_TIMEOUT"; then
      echo "error: $ID did not confirm stow within ${STOW_TIMEOUT}s; aborting before exit. Rerun with --skip-stow only if the lane is already stowed or safe to restart." >&2
      exit 1
    fi
  fi
  graceful_exit_sequence
  if ! wait_for_exit "$TIMEOUT"; then
    if [ "$FORCE" -ne 1 ]; then
      echo "error: $ID did not exit within ${TIMEOUT}s; rerun with --force to interrupt and restart it" >&2
      exit 1
    fi
    echo "restart: $ID did not exit within ${TIMEOUT}s; forcing harness exit"
    force_exit_sequence
    if ! wait_for_exit "$FORCE_TIMEOUT"; then
      echo "restart: force exit did not stop $ID within ${FORCE_TIMEOUT}s; closing old endpoint during cleanup" >&2
    fi
  fi
else
  echo "restart: $ID endpoint is already dead; respawning"
fi

cleanup_and_respawn
echo "restart: $ID refreshed"
