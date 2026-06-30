#!/usr/bin/env bash
# Print the tail of a crewmate terminal (bounded, for cheap diagnosis).
# Usage: fm-peek.sh <target> [lines=40]
#   <target> may be a bare firstmate target (fm-xyz), resolved through this
#   home's state/<id>.meta, or explicit session:window for tmux.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-terminal-lib.sh
. "$SCRIPT_DIR/fm-terminal-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

N=${2:-40}
fm_terminal_read "$1" "$N"
