#!/usr/bin/env bash
# Shared FM_HOME ownership guard.
# Usage: . bin/fm-home-guard-lib.sh, then fm_home_guard <read|mutate> <command-name>
#
# The guard is intentionally narrow: when the caller is currently inside a
# seeded secondmate home, that home is the owned context, so a mutating fm-*
# command must not operate against any other FM_HOME. Read-only commands warn
# and continue; mutating commands refuse with remediation. Primary homes are
# left unchanged because they have no durable per-home ownership marker yet.

fm_home_guard_real_dir() {
  local path=$1
  [ -d "$path" ] || return 1
  cd "$path" 2>/dev/null && pwd -P
}

fm_home_guard_context_home() {
  local top
  command -v git >/dev/null 2>&1 || return 1
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -f "$top/.fm-secondmate-home" ] || return 1
  [ -f "$top/AGENTS.md" ] || return 1
  [ -d "$top/bin" ] || return 1
  fm_home_guard_real_dir "$top"
}

fm_home_guard_effective_home() {
  local home=${FM_HOME:-}
  [ -n "$home" ] || return 1
  fm_home_guard_real_dir "$home"
}

fm_home_guard() {
  local mode=${1:-mutate} command_name=${2:-fm command} context_home effective_home marker
  context_home=$(fm_home_guard_context_home) || return 0
  effective_home=$(fm_home_guard_effective_home) || return 0
  [ "$context_home" = "$effective_home" ] && return 0

  marker=$(cat "$context_home/.fm-secondmate-home" 2>/dev/null || true)
  case "$mode" in
    read)
      echo "warning: $command_name is running from secondmate home '$context_home' (${marker:-unknown}) but FM_HOME resolves to '$effective_home'; read-only command continuing. Set FM_HOME='$context_home' or cd into the intended home before mutating." >&2
      return 0
      ;;
    *)
      echo "error: $command_name refuses to mutate FM_HOME '$effective_home' from secondmate home '$context_home' (${marker:-unknown})." >&2
      echo "Set FM_HOME='$context_home' for this lane, or run the command from the home that owns '$effective_home'." >&2
      return 1
      ;;
  esac
}
