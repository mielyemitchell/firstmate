#!/usr/bin/env bash
# Run tasks-axi against the effective firstmate home, regardless of caller cwd.
# Usage: fm-tasks-axi.sh <tasks-axi args...>
#
# tasks-axi discovers `.tasks.toml` from cwd. Firstmate homes all carry the
# tracked config that points at data/backlog.md, so this wrapper changes to
# FM_HOME first and refuses write-capable verbs unless that config resolves back
# inside FM_HOME. This closes the repo-root cwd trap without forking tasks-axi.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-home-guard-lib.sh
. "$SCRIPT_DIR/fm-home-guard-lib.sh"

verb=${1:-}
case "$verb" in
  add|start|done|update|block|unblock|render|mv)
    fm_home_guard mutate "fm-tasks-axi.sh" || exit 1
    ;;
  *)
    fm_home_guard read "fm-tasks-axi.sh" || exit 1
    ;;
esac

[ -d "$FM_HOME" ] || { echo "error: FM_HOME '$FM_HOME' is not a directory" >&2; exit 1; }
[ -f "$FM_HOME/.tasks.toml" ] || { echo "error: $FM_HOME/.tasks.toml is missing; cannot safely run tasks-axi for this home" >&2; exit 1; }
command -v tasks-axi >/dev/null 2>&1 || { echo "error: tasks-axi is not on PATH" >&2; exit 127; }

tasks_path=$(sed -n 's/^[[:space:]]*path[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$FM_HOME/.tasks.toml" | head -1)
[ -n "$tasks_path" ] || { echo "error: $FM_HOME/.tasks.toml does not declare a markdown path" >&2; exit 1; }
case "$tasks_path" in
  /*) backlog_path=$tasks_path ;;
  *) backlog_path=$FM_HOME/$tasks_path ;;
esac
backlog_dir=$(dirname "$backlog_path")
mkdir -p "$backlog_dir"
home_real=$(cd "$FM_HOME" && pwd -P)
backlog_dir_real=$(cd "$backlog_dir" && pwd -P)
case "$backlog_dir_real/" in
  "$home_real"/*) ;;
  *) echo "error: tasks-axi config path '$tasks_path' resolves outside FM_HOME '$home_real'" >&2; exit 1 ;;
esac

cd "$FM_HOME"
exec tasks-axi "$@"
