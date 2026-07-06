#!/usr/bin/env bash
# fm-freeze.sh - park or unpark firstmate's live fleet locally.
#
# Usage:
#   fm-freeze.sh on [reason...]
#   fm-freeze.sh off
#   fm-freeze.sh status
#
# The freeze file makes spawn/steer commands refuse while the fleet is parked.
# It is local, gitignored operational state. This script does not inspect,
# terminate, or mutate any crewmate; it only toggles the guard flag.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-freeze-lib.sh
. "$SCRIPT_DIR/fm-freeze-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-freeze.sh on [reason...]
  fm-freeze.sh off
  fm-freeze.sh status

Freeze is local operational state. It blocks fm-spawn.sh, fm-send.sh,
fm-watch.sh, fm-watch-arm.sh, and away-mode daemon injection unless
FM_FLEET_FREEZE_BYPASS=1 is set for that specific command.
EOF
}

cmd=${1:-status}
case "$cmd" in
  -h|--help)
    usage
    exit 0
    ;;
  on)
    shift
    mkdir -p "$STATE"
    {
      printf 'created_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf 'home=%s\n' "$FM_HOME"
      printf 'reason=%s\n' "${*:-manual freeze}"
    } > "$(fm_fleet_freeze_path)"
    printf 'fleet frozen: %s\n' "$(fm_fleet_freeze_path)"
    ;;
  off)
    if [ -f "$(fm_fleet_freeze_path)" ]; then
      rm -f "$(fm_fleet_freeze_path)"
      printf 'fleet unfrozen\n'
    else
      printf 'fleet already unfrozen\n'
    fi
    ;;
  status)
    if [ -f "$(fm_fleet_freeze_path)" ]; then
      printf 'fleet frozen: %s\n' "$(fm_fleet_freeze_path)"
      cat "$(fm_fleet_freeze_path)"
    else
      printf 'fleet unfrozen\n'
    fi
    ;;
  *)
    echo "error: unknown command '$cmd'" >&2
    usage >&2
    exit 2
    ;;
esac
