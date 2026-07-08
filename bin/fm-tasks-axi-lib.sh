# shellcheck shell=bash
# Shared tasks-axi backend selection and compatibility probe for bootstrap and
# teardown.
# Usage: . bin/fm-tasks-axi-lib.sh
# Compatible means tasks-axi --version reports 0.1.1 or newer.
# `config/backlog-backend=manual` opts out; absent or any other value keeps the
# default tasks-axi backend path, falling back to manual when the tool is not
# compatible.

fm_tasks_axi_version_parts() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi --version 2>/dev/null) || return 1
  printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1
}

fm_tasks_axi_compatible() {
  local parts major minor patch rest
  parts=$(fm_tasks_axi_version_parts) || return 1
  [ -n "$parts" ] || return 1
  major=${parts%% *}
  rest=${parts#* }
  minor=${rest%% *}
  patch=${rest##* }

  [ "$major" -gt 0 ] && return 0
  [ "$major" -eq 0 ] && [ "$minor" -gt 1 ] && return 0
  [ "$major" -eq 0 ] && [ "$minor" -eq 1 ] && [ "$patch" -ge 1 ] && return 0
  return 1
}

fm_backlog_backend_value() {
  local config_dir=$1 backend_file value
  backend_file="$config_dir/backlog-backend"
  if [ -f "$backend_file" ]; then
    value=$(tr -d '[:space:]' < "$backend_file" 2>/dev/null || true)
    [ -n "$value" ] || value=tasks-axi
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s\n' tasks-axi
}

fm_backlog_backend_manual() {
  local config_dir=$1
  [ "$(fm_backlog_backend_value "$config_dir")" = manual ]
}

fm_tasks_axi_backend_available() {
  local config_dir=$1
  fm_backlog_backend_manual "$config_dir" && return 1
  fm_tasks_axi_compatible
}

fm_tasks_axi_cwd_trap_warning() {
  local root=$1 home=$2 root_real home_real root_backlog home_backlog
  root_real=$(cd "$root" 2>/dev/null && pwd -P) || return 0
  home_real=$(cd "$home" 2>/dev/null && pwd -P) || return 0
  [ "$root_real" != "$home_real" ] || return 0
  root_backlog="$root_real/data/backlog.md"
  home_backlog="$home_real/data/backlog.md"
  [ -f "$root_backlog" ] || return 0
  [ -f "$home_backlog" ] || return 0
  cmp -s "$root_backlog" "$home_backlog" && return 0
  printf 'TASKS_AXI: repo-root data/backlog.md differs from FM_HOME backlog - use bin/fm-tasks-axi.sh so tasks-axi runs from %s\n' "$home_real"
}
