#!/usr/bin/env bash
# fm-fleet-map.sh - read-only inventory of firstmate task state vs live agents.
#
# This is a diagnostic guardrail for the failure mode where firstmate's state
# and the human-visible backend surface drift apart. It never spawns, steers,
# tears down, edits state, or starts a Herdr server. It only reads state,
# backend endpoint liveness, and `herdr agent list` when available.
#
# Test fixtures may set FM_FLEET_MAP_HERDR_JSON to a saved `herdr agent list`
# JSON file. When Herdr is unavailable, the tracked-state section still prints,
# and non-Herdr endpoints are still checked through the backend liveness probe.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-fleet-map-lib.sh
. "$SCRIPT_DIR/fm-fleet-map-lib.sh"

usage() {
  cat <<'EOF'
Usage: fm-fleet-map.sh

Print a read-only map of firstmate's recorded fleet state and visible Herdr
agents. This is for diagnosis only; it does not mutate anything.

Environment:
  FM_HOME                    firstmate operational home
  FM_STATE_OVERRIDE          override state directory
  FM_FLEET_MAP_HERDR_JSON    parse this Herdr JSON fixture instead of calling herdr
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  "")
    ;;
  *)
    echo "error: unknown argument '$1'" >&2
    usage >&2
    exit 2
    ;;
esac

TMPDIR_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-fleet-map.XXXXXX") || exit 1
cleanup() {
  rm -rf "$TMPDIR_ROOT"
}
trap cleanup EXIT

fm_fleet_map_init "$TMPDIR_ROOT"

print_report() {
  local id kind backend target cwd agent cwd_agent name status terminal agent_cwd agent_target tracked_ids match
  printf 'FIRSTMATE FLEET MAP\n'
  printf 'home=%s\n' "$FM_HOME"
  printf 'state=%s\n' "$FM_STATE"
  printf '\n'

  printf 'TRACKED STATE\n'
  if [ ! -s "$TRACKED" ]; then
    printf 'none\n'
  else
    printf 'id\tkind\tbackend\ttarget\tcwd\tmatched_herdr\n'
    while IFS=$'\t' read -r id kind backend target cwd; do
      agent=$(herdr_agent_for_target "$target" || true)
      cwd_agent=$(herdr_agent_for_cwd "$cwd" || true)
      if [ "$backend" = herdr ] && [ -n "$agent" ]; then
        match="target-match:$agent"
      elif [ "$backend" = herdr ] && [ -n "$cwd_agent" ]; then
        match="cwd-only:$cwd_agent"
      else
        match="none"
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$kind" "$backend" "$target" "$cwd" "$match"
    done < "$TRACKED"
  fi
  printf '\n'

  printf 'HERDR AGENTS\n'
  if [ "$HERDR_AVAILABLE" != 1 ]; then
    printf 'unavailable\n'
  elif [ ! -s "$HERDR_AGENTS" ]; then
    printf 'none\n'
  else
    printf 'name\tstatus\tterminal\ttarget\tcwd\ttracked_ids\n'
    while IFS=$'\t' read -r name status terminal agent_cwd agent_target; do
      tracked_ids=$(tracked_ids_for_agent "$agent_target" "$agent_cwd")
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$status" "$terminal" "$agent_target" "$agent_cwd" "${tracked_ids:-none}"
    done < "$HERDR_AGENTS"
  fi
  printf '\n'

  printf 'WARNINGS\n'
  if [ ! -s "$WARNINGS" ]; then
    printf 'none\n'
  else
    cat "$WARNINGS"
  fi
}

fm_fleet_map_read_tracked_state
fm_fleet_map_read_live_agents
fm_fleet_map_write_mismatch_warnings
print_report
