#!/usr/bin/env bash
# fm-freeze-lib.sh - shared fleet-freeze guard for dispatch/steer commands.
#
# Sourcing scripts must define STATE before loading this file. The freeze file is
# local operational state, not tracked config. It is intentionally blunt:
# commands that would wake, spawn, or steer agents refuse while frozen unless an
# operator sets FM_FLEET_FREEZE_BYPASS=1 for that exact command.

fm_fleet_freeze_path() {  # [state-dir]
  local state=${1:-$STATE}
  printf '%s/.fleet-freeze' "$state"
}

fm_fleet_freeze_reason() {  # [state-dir]
  local file
  file=$(fm_fleet_freeze_path "${1:-$STATE}")
  [ -f "$file" ] || return 0
  grep '^reason=' "$file" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_fleet_freeze_refuse() {  # <action> [state-dir]
  local action=$1 state=${2:-$STATE} file reason
  [ "${FM_FLEET_FREEZE_BYPASS:-}" = 1 ] && return 0
  file=$(fm_fleet_freeze_path "$state")
  [ -f "$file" ] || return 0
  reason=$(fm_fleet_freeze_reason "$state")
  echo "error: fleet frozen: $action refused (state: $file${reason:+; reason: $reason})" >&2
  echo "Set FM_FLEET_FREEZE_BYPASS=1 for a deliberate one-command override, or run bin/fm-freeze.sh off." >&2
  return 1
}
