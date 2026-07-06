#!/usr/bin/env bash
# fm-reconcile-stale.sh - dry-run-first cleanup for stale tracked task state.
#
# Default mode is a report only. It lists stale tracked records, shows the
# recorded backend target and worktree/home path, assesses whether the recorded
# work path holds unlanded work, and surfaces operator-untracked Herdr agents.
#
# Cleanup is explicit and per-id:
#   fm-reconcile-stale.sh --clean <id> --yes
#
# Cleanup re-verifies the endpoint is dead and the work path has no unlanded
# work, then removes only volatile firstmate state for that id. It never removes
# worktrees, secondmate homes, project clones, branches, or backend endpoints.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_STATE="$STATE"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-fleet-map-lib.sh
. "$SCRIPT_DIR/fm-fleet-map-lib.sh"
# shellcheck source=bin/fm-landed-work-lib.sh
. "$SCRIPT_DIR/fm-landed-work-lib.sh"
# shellcheck source=bin/fm-freeze-lib.sh
. "$SCRIPT_DIR/fm-freeze-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-reconcile-stale.sh
  fm-reconcile-stale.sh --clean <id> [--yes]

Default mode is a dry run. It reports stale tracked task records, landed-work
assessment, and operator-untracked Herdr agents. It does not modify state.

Cleanup mode removes only volatile state for one stale task id after re-checking
that the backend endpoint is dead and the recorded work path has no unlanded
work. --yes is required for mutation.

Environment:
  FM_HOME                    firstmate operational home
  FM_STATE_OVERRIDE          override state directory
  FM_FLEET_MAP_HERDR_JSON    parse this Herdr JSON fixture instead of calling herdr
  FM_FLEET_FREEZE_BYPASS=1   allow --clean --yes while fleet freeze is active
EOF
}

mode=dry-run
clean_id=
yes=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --clean)
      mode=clean
      shift
      clean_id=${1:-}
      [ -n "$clean_id" ] || { echo "error: --clean requires an id" >&2; exit 2; }
      ;;
    --yes)
      yes=1
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

TMPDIR_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-reconcile-stale.XXXXXX") || exit 1
cleanup() {
  rm -rf "$TMPDIR_ROOT"
}
trap cleanup EXIT

fm_fleet_map_init "$TMPDIR_ROOT"
fm_fleet_map_read_tracked_state
fm_fleet_map_read_live_agents
fm_fleet_map_write_mismatch_warnings

field_from_warning() {  # <line> <key>
  local line=$1 key=$2 rest value
  rest=${line#*"$key="}
  [ "$rest" != "$line" ] || return 1
  value=${rest%% *}
  printf '%s' "$value"
}

task_work_path_from_meta() {  # <meta>
  local meta=$1 v
  v=$(meta_value "$meta" worktree)
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  v=$(meta_value "$meta" home)
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  return 0
}

print_landed_assessment() {  # <id> <meta>
  local id=$1 meta=$2 work project mode kind report assessment rc status detail
  work=$(task_work_path_from_meta "$meta")
  project=$(meta_value "$meta" project)
  mode=$(meta_value "$meta" mode)
  kind=$(meta_value "$meta" kind)
  report="$DATA/$id/report.md"
  assessment=$(fm_landed_assess_worktree "$work" "$project" "${mode:-no-mistakes}" "${kind:-ship}" "$report")
  rc=$?
  status=${assessment%%$'\t'*}
  detail=${assessment#*$'\t'}
  printf 'id=%s landed=%s detail=%s\n' "$id" "$status" "$detail"
  return "$rc"
}

print_dry_run() {
  local line id backend target cwd meta kind work project mode report assessment status detail found=0
  printf 'FIRSTMATE STALE STATE RECONCILE DRY RUN\n'
  printf 'home=%s\n' "$FM_HOME"
  printf 'state=%s\n' "$STATE"
  printf '\n'

  printf 'STALE TRACKED RECORDS\n'
  while IFS= read -r line; do
    case "$line" in
      stale-tracked\ *) ;;
      *) continue ;;
    esac
    found=1
    id=$(field_from_warning "$line" id)
    backend=$(field_from_warning "$line" backend)
    target=$(field_from_warning "$line" target)
    cwd=$(field_from_warning "$line" cwd)
    meta="$STATE/$id.meta"
    kind=$(meta_value "$meta" kind)
    work=$(task_work_path_from_meta "$meta")
    project=$(meta_value "$meta" project)
    mode=$(meta_value "$meta" mode)
    report="$DATA/$id/report.md"
    assessment=$(fm_landed_assess_worktree "$work" "$project" "${mode:-no-mistakes}" "${kind:-ship}" "$report")
    status=${assessment%%$'\t'*}
    detail=${assessment#*$'\t'}
    printf 'id=%s kind=%s backend=%s target=%s path=%s fleet_cwd=%s landed=%s detail=%s\n' \
      "$id" "${kind:-ship}" "$backend" "$target" "${work:--}" "$cwd" "$status" "$detail"
  done < "$WARNINGS"
  [ "$found" = 1 ] || printf 'none\n'
  printf '\n'

  printf 'OPERATOR-UNTRACKED LIVE AGENTS\n'
  found=0
  while IFS= read -r line; do
    case "$line" in
      operator-untracked-herdr\ *)
        found=1
        printf '%s\n' "$line"
        ;;
    esac
  done < "$WARNINGS"
  [ "$found" = 1 ] || printf 'none\n'
  printf '\n'
  printf 'No files were modified. Use --clean <id> --yes to remove one dead, landed state record.\n'
}

meta_for_clean_id() {
  local meta="$STATE/$clean_id.meta"
  [ -f "$meta" ] || { echo "error: no meta for task $clean_id at $meta" >&2; return 1; }
  printf '%s' "$meta"
}

clean_id_is_stale_tracked() {
  grep -F "stale-tracked id=$clean_id " "$WARNINGS" >/dev/null 2>&1
}

remove_grok_turnend_auth() {
  local state_dir=$1 id=$2 token hooks_dir
  token=$(cat "$state_dir/$id.grok-turnend-token" 2>/dev/null || true)
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  hooks_dir="${GROK_HOME:-$HOME/.grok}/hooks/fm-turn-end.d"
  rm -f "$hooks_dir/$token"
}

safe_remove_tasktmp() {  # <id> <tasktmp>
  local id=$1 tasktmp=$2 base
  [ -n "$tasktmp" ] || return 0
  [ -e "$tasktmp" ] || return 0
  base=$(basename "$tasktmp")
  if [ "$base" != "fm-$id" ]; then
    echo "error: refusing unsafe tasktmp removal target: $tasktmp" >&2
    return 1
  fi
  case "$tasktmp" in
    ''|/) echo "error: refusing unsafe tasktmp removal target: $tasktmp" >&2; return 1 ;;
  esac
  rm -rf -- "$tasktmp"
}

print_clean_plan() {  # <meta>
  local meta=$1 tasktmp
  tasktmp=$(meta_value "$meta" tasktmp)
  printf 'would remove:\n'
  printf '  %s/%s.meta\n' "$STATE" "$clean_id"
  printf '  %s/%s.status\n' "$STATE" "$clean_id"
  printf '  %s/%s.turn-ended\n' "$STATE" "$clean_id"
  printf '  %s/%s.check.sh\n' "$STATE" "$clean_id"
  printf '  %s/%s.pi-ext.ts\n' "$STATE" "$clean_id"
  printf '  %s/%s.grok-turnend-token\n' "$STATE" "$clean_id"
  [ -n "$tasktmp" ] && printf '  %s\n' "$tasktmp"
}

run_clean() {
  local meta backend target zellij_tab_id tasktmp assessment_rc=0
  meta=$(meta_for_clean_id) || return 1
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  zellij_tab_id=$(meta_value "$meta" zellij_tab_id)

  if fm_fleet_map_backend_target_exists "$backend" "$target" "$clean_id" "$zellij_tab_id"; then
    echo "REFUSED: task $clean_id still has a live $backend endpoint at $target." >&2
    echo "Use bin/fm-teardown.sh $clean_id when the task is finished, or close the endpoint before stale-state reconciliation." >&2
    return 1
  fi
  if ! clean_id_is_stale_tracked; then
    echo "REFUSED: task $clean_id is not currently classified as stale-tracked by fleet-map matching." >&2
    return 1
  fi

  print_landed_assessment "$clean_id" "$meta" || assessment_rc=$?
  if [ "$assessment_rc" -ne 0 ]; then
    echo "REFUSED: recorded work path may hold unlanded work." >&2
    echo "Use bin/fm-teardown.sh $clean_id after the work lands, or recover the task endpoint." >&2
    return 1
  fi

  print_clean_plan "$meta"
  if [ "$yes" != 1 ]; then
    echo "REFUSED: --clean requires --yes to mutate state." >&2
    return 1
  fi

  fm_fleet_freeze_refuse "stale-state cleanup" "$STATE" || return 1
  tasktmp=$(meta_value "$meta" tasktmp)
  remove_grok_turnend_auth "$STATE" "$clean_id"
  safe_remove_tasktmp "$clean_id" "$tasktmp" || return 1
  rm -f \
    "$STATE/$clean_id.status" \
    "$STATE/$clean_id.turn-ended" \
    "$STATE/$clean_id.check.sh" \
    "$STATE/$clean_id.meta" \
    "$STATE/$clean_id.pi-ext.ts" \
    "$STATE/$clean_id.grok-turnend-token"
  printf 'cleaned stale state for %s\n' "$clean_id"
}

case "$mode" in
  dry-run) print_dry_run ;;
  clean) run_clean ;;
esac
