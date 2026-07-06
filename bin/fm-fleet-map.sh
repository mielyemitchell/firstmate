#!/usr/bin/env bash
# fm-fleet-map.sh - read-only inventory of firstmate task state vs visible Herdr agents.
#
# This is a diagnostic guardrail for the failure mode where firstmate's state
# and the human-visible Herdr surface drift apart. It never spawns, steers,
# tears down, edits state, or starts a Herdr server. It only reads:
#   - state/*.meta records
#   - `herdr agent list` when available
#
# Test fixtures may set FM_FLEET_MAP_HERDR_JSON to a saved `herdr agent list`
# JSON file. When Herdr is unavailable, the tracked-state section still prints,
# but Herdr mismatch warnings are skipped because there is no live inventory.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

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

TRACKED="$TMPDIR_ROOT/tracked.tsv"
HERDR_AGENTS="$TMPDIR_ROOT/herdr.tsv"
WARNINGS="$TMPDIR_ROOT/warnings.txt"
: > "$TRACKED"
: > "$HERDR_AGENTS"
: > "$WARNINGS"

meta_value() {  # <meta> <key>
  fm_meta_get "$1" "$2"
}

task_cwd_from_meta() {  # <meta>
  local meta=$1 v
  v=$(meta_value "$meta" worktree)
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  v=$(meta_value "$meta" home)
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  v=$(meta_value "$meta" project)
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  return 0
}

read_tracked_state() {
  local meta id kind backend target cwd
  for meta in "$FM_STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(meta_value "$meta" kind)
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    cwd=$(task_cwd_from_meta "$meta")
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$id" "${kind:-task}" "${backend:-tmux}" "${target:--}" "${cwd:--}" >> "$TRACKED"
  done
}

load_herdr_json() {
  if [ -n "${FM_FLEET_MAP_HERDR_JSON:-}" ]; then
    [ -f "$FM_FLEET_MAP_HERDR_JSON" ] || {
      echo "warning: FM_FLEET_MAP_HERDR_JSON does not exist: $FM_FLEET_MAP_HERDR_JSON" >> "$WARNINGS"
      return 1
    }
    cat "$FM_FLEET_MAP_HERDR_JSON"
    return 0
  fi

  command -v herdr >/dev/null 2>&1 || return 1
  herdr agent list 2>/dev/null || return 1
}

read_herdr_agents() {
  command -v jq >/dev/null 2>&1 || return 1
  local json
  json=$(load_herdr_json) || return 1
  [ -n "$json" ] || return 1
  printf '%s' "$json" | jq -r '
    .result.agents[]? |
    . as $agent |
    (($agent.session // $agent.herdr_session // env.HERDR_SESSION // "default") + ":" + ($agent.pane_id // "")) as $target |
    [
      (.name // .agent // "-"),
      (.agent_status // .status // .state // "-"),
      (.terminal_id // .terminal // .pane_id // "-"),
      (.cwd // .working_directory // "-"),
      (if ($agent.pane_id // "") == "" then "-" else $target end)
    ] | @tsv
  ' 2>/dev/null > "$HERDR_AGENTS" || return 1
  return 0
}

herdr_agent_for_target() {  # <target>
  local want=$1 name status terminal cwd target
  while IFS=$'\t' read -r name status terminal cwd target; do
    [ -n "$name" ] || continue
    [ "$target" = "$want" ] || continue
    printf '%s' "$name"
    return 0
  done < "$HERDR_AGENTS"
  return 1
}

tracked_ids_for_cwd() {  # <cwd>
  local want=$1 id kind backend target cwd ids=""
  while IFS=$'\t' read -r id kind backend target cwd; do
    [ -n "$id" ] || continue
    [ "$cwd" = "$want" ] || continue
    if [ -n "$ids" ]; then
      ids="$ids,$id"
    else
      ids="$id"
    fi
  done < "$TRACKED"
  printf '%s' "$ids"
}

tracked_ids_for_target() {  # <target>
  local want=$1 id kind backend target cwd ids=""
  while IFS=$'\t' read -r id kind backend target cwd; do
    [ -n "$id" ] || continue
    [ "$target" = "$want" ] || continue
    if [ -n "$ids" ]; then
      ids="$ids,$id"
    else
      ids="$id"
    fi
  done < "$TRACKED"
  printf '%s' "$ids"
}

tracked_ids_for_agent() {  # <target> <cwd>
  local ids
  ids=$(tracked_ids_for_target "$1")
  [ -n "$ids" ] && { printf '%s' "$ids"; return 0; }
  tracked_ids_for_cwd "$2"
}

herdr_agent_for_cwd() {  # <cwd>
  local want=$1 name status terminal cwd target
  while IFS=$'\t' read -r name status terminal cwd target; do
    [ -n "$name" ] || continue
    [ "$cwd" = "$want" ] || continue
    printf '%s' "$name"
    return 0
  done < "$HERDR_AGENTS"
  return 1
}

write_mismatch_warnings() {
  local id kind backend target cwd agent cwd_agent name status terminal agent_cwd agent_target tracked_ids
  while IFS=$'\t' read -r id kind backend target cwd; do
    [ -n "$id" ] || continue
    [ "$backend" = herdr ] || continue
    agent=$(herdr_agent_for_target "$target" || true)
    cwd_agent=$(herdr_agent_for_cwd "$cwd" || true)
    if [ -n "$agent" ]; then
      :
    elif [ -n "$cwd_agent" ]; then
      printf 'cwd-only-match id=%s backend=%s target=%s cwd=%s herdr=%s\n' "$id" "$backend" "$target" "$cwd" "$cwd_agent" >> "$WARNINGS"
    else
      printf 'stale-tracked id=%s backend=%s target=%s cwd=%s\n' "$id" "$backend" "$target" "$cwd" >> "$WARNINGS"
    fi
  done < "$TRACKED"

  while IFS=$'\t' read -r name status terminal agent_cwd agent_target; do
    [ -n "$name" ] || continue
    tracked_ids=$(tracked_ids_for_agent "$agent_target" "$agent_cwd")
    if [ -z "$tracked_ids" ]; then
      printf 'operator-untracked-herdr name=%s status=%s terminal=%s target=%s cwd=%s\n' "$name" "$status" "$terminal" "$agent_target" "$agent_cwd" >> "$WARNINGS"
    fi
  done < "$HERDR_AGENTS"
}

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
      if [ -n "$agent" ]; then
        match="target-match:$agent"
      elif [ -n "$cwd_agent" ]; then
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

read_tracked_state
HERDR_AVAILABLE=0
if read_herdr_agents; then
  HERDR_AVAILABLE=1
  write_mismatch_warnings
else
  printf 'herdr-unavailable no live Herdr inventory was read\n' >> "$WARNINGS"
fi
print_report
