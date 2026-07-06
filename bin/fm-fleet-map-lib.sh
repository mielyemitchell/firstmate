#!/usr/bin/env bash
# fm-fleet-map-lib.sh - shared tracked-state/live-endpoint reconciliation helpers.
#
# Source after defining SCRIPT_DIR, FM_HOME, and FM_STATE.
# Call fm_fleet_map_init <tmpdir>, then fm_fleet_map_read_tracked_state,
# fm_fleet_map_read_live_agents, and fm_fleet_map_write_mismatch_warnings.

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

fm_fleet_map_init() {  # <tmpdir>
  local tmpdir=$1
  TRACKED="$tmpdir/tracked.tsv"
  HERDR_AGENTS="$tmpdir/herdr.tsv"
  WARNINGS="$tmpdir/warnings.txt"
  : > "$TRACKED"
  : > "$HERDR_AGENTS"
  : > "$WARNINGS"
  HERDR_AVAILABLE=0
}

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

fm_fleet_map_read_tracked_state() {
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

fm_fleet_map_load_herdr_json() {
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

fm_fleet_map_read_herdr_agents() {
  command -v jq >/dev/null 2>&1 || return 1
  local json
  json=$(fm_fleet_map_load_herdr_json) || return 1
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

fm_fleet_map_backend_target_exists() {  # <backend> <target> <id> [zellij-tab-id]
  local backend=$1 target=$2 id=$3 zellij_tab_id=${4:-}
  [ -n "$target" ] && [ "$target" != "-" ] || return 1
  if [ "$backend" = zellij ]; then
    fm_backend_target_exists "$backend" "$target" "$zellij_tab_id" "fm-$id"
  else
    fm_backend_target_exists "$backend" "$target" "fm-$id"
  fi
}

fm_fleet_map_write_mismatch_warnings() {
  local id kind backend target cwd agent cwd_agent name status terminal agent_cwd agent_target tracked_ids meta zellij_tab_id
  while IFS=$'\t' read -r id kind backend target cwd; do
    [ -n "$id" ] || continue
    if [ "$backend" = herdr ]; then
      [ "${HERDR_AVAILABLE:-0}" = 1 ] || continue
      agent=$(herdr_agent_for_target "$target" || true)
      cwd_agent=$(herdr_agent_for_cwd "$cwd" || true)
      if [ -n "$agent" ]; then
        :
      elif [ -n "$cwd_agent" ]; then
        printf 'cwd-only-match id=%s backend=%s target=%s cwd=%s herdr=%s\n' "$id" "$backend" "$target" "$cwd" "$cwd_agent" >> "$WARNINGS"
      else
        printf 'stale-tracked id=%s backend=%s target=%s cwd=%s\n' "$id" "$backend" "$target" "$cwd" >> "$WARNINGS"
      fi
      continue
    fi

    meta="$FM_STATE/$id.meta"
    zellij_tab_id=$(meta_value "$meta" zellij_tab_id)
    if ! fm_fleet_map_backend_target_exists "$backend" "$target" "$id" "$zellij_tab_id"; then
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

fm_fleet_map_read_live_agents() {
  if fm_fleet_map_read_herdr_agents; then
    # shellcheck disable=SC2034 # consumed by callers after sourcing this library
    HERDR_AVAILABLE=1
  else
    printf 'herdr-unavailable no live Herdr inventory was read\n' >> "$WARNINGS"
  fi
}
