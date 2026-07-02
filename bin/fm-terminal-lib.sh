#!/usr/bin/env bash
# fm-terminal-lib.sh — backend-neutral terminal targeting for firstmate.
# Source from scripts that need to send, read, classify, or close a direct report
# without assuming every report is a tmux window.

# shellcheck source=bin/fm-tmux-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-tmux-lib.sh"

FM_TERMINAL_BUSY_REGEX_DEFAULT='esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel'

fm_terminal_meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_terminal_config_backend() {  # -> tmux|cmux
  local config_dir=${FM_CONFIG_OVERRIDE:-${CONFIG:-${FM_HOME:-}/config}} raw
  raw=auto
  [ -n "$config_dir" ] && [ -f "$config_dir/terminal-backend" ] && raw=$(tr -d '[:space:]' < "$config_dir/terminal-backend")
  [ -n "$raw" ] || raw=auto
  case "$raw" in
    tmux|cmux) printf '%s\n' "$raw" ;;
    auto)
      if [ -n "${CMUX_WORKSPACE_ID:-}" ] && command -v cmux >/dev/null 2>&1 && cmux ping >/dev/null 2>&1; then
        printf 'cmux\n'
      else
        printf 'tmux\n'
      fi
      ;;
    *) echo "error: invalid terminal backend '$raw' in $config_dir/terminal-backend (expected tmux, cmux, or auto)" >&2; return 2 ;;
  esac
}

# --- cmux multi-worker layout policy ---------------------------------------
#
# Placement policy for a NEW cmux worker, given how many cmux workers this home
# already has. Mielye default (auto): firstmate's own pane stays pinned on the
# LEFT and is never sliced into a strip; workers tile into a 2-row grid to its
# right (a 2x2 for the default capacity of 4). When the grid is full the next
# worker opens a NEW cmux window and the grid fills again there. Explicit
# config/cmux-layout values force one shape:
#   splits - a visible right-split off firstmate per worker (vertical strips).
#   tabs   - one crew pane (first worker splits) then worker tabs.
#   hybrid - split up to FM_CMUX_SPLIT_THRESHOLD, then tab overflow (the pre-grid
#            "auto" behaviour, kept available under its own name).
#   auto   - grid + new-window overflow (the new default described above).
#
# Grid tiling detail (auto), column-major over FM_CMUX_GRID_ROWS rows:
#   worker 1 -> new-split right off firstmate's caller surface (top-right cell)
#   worker 2 -> new-split down off worker 1  (bottom of column 1)
#   worker 3 -> new-split right off worker 1 (top of column 2)
#   worker 4 -> new-split down off worker 3  (bottom of column 2)
#   worker 5 -> new cmux window (grid at capacity); `cmux new-window` auto-creates
#              a default workspace + terminal surface in that window (resolved via
#              `cmux identify`, not a separate new-workspace/new-pane call), then
#              the grid fills again there.
# Anchors are resolved from the recorded worker surfaces/workspaces in
# state/*.meta, ordered by cmux's monotonically-increasing surface ref (a later
# worker gets a higher surface number), so the ordering is stable across meta
# appends and across windows.
#
# FM_CMUX_SPLIT_THRESHOLD is the max number of EXISTING workers that still get a
# split under hybrid: a new worker splits while count < threshold and overflows
# to a tab once count >= threshold (so with 3, workers 1-3 split and worker 4+
# tabs). Named so it is obvious and tunable.
FM_CMUX_SPLIT_THRESHOLD=${FM_CMUX_SPLIT_THRESHOLD:-3}
# FM_CMUX_GRID_CAPACITY is how many workers fill one grid (one window) before the
# next worker overflows to a new window. Default 4 = the 2x2 grid.
FM_CMUX_GRID_CAPACITY=${FM_CMUX_GRID_CAPACITY:-4}
# FM_CMUX_GRID_ROWS is the grid height (rows per column). The grid fills
# column-major: each column is filled top-to-bottom before the next column opens
# to its right. Default 2 gives the 2x2 grid at the default capacity.
FM_CMUX_GRID_ROWS=${FM_CMUX_GRID_ROWS:-2}

fm_terminal_cmux_layout() {  # -> splits|tabs|hybrid|auto
  local config_dir=${FM_CONFIG_OVERRIDE:-${CONFIG:-${FM_HOME:-}/config}} raw
  raw=auto
  [ -n "$config_dir" ] && [ -f "$config_dir/cmux-layout" ] && raw=$(tr -d '[:space:]' < "$config_dir/cmux-layout")
  [ -n "$raw" ] || raw=auto
  case "$raw" in
    splits|tabs|hybrid|auto) printf '%s\n' "$raw" ;;
    *) echo "error: invalid cmux layout '$raw' in $config_dir/cmux-layout (expected splits, tabs, hybrid, or auto)" >&2; return 2 ;;
  esac
}

# Count live cmux workers this home already has: state/<id>.meta with
# terminal_backend=cmux, excluding only the task being spawned. Secondmates count
# like any other cmux worker (Phase B slice 3): a cmux secondmate is a first-class
# visible worker, so it participates in the layout count for its own placement and
# for later workers' placement.
fm_terminal_cmux_worker_count() {  # <exclude-id> -> N
  local exclude=$1 state=${STATE:?STATE required} meta base n=0
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    base=$(basename "$meta" .meta)
    [ "$base" = "$exclude" ] && continue
    [ "$(fm_terminal_meta_value "$meta" terminal_backend)" = cmux ] || continue
    n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# Decide placement for a new worker. N is the existing cmux worker count.
# Returns: split (right-split off firstmate), tab (overflow surface in a worker
# pane), grid (auto grid placement, resolve direction+anchor via grid_slot), or
# window (auto overflow to a new cmux window).
fm_terminal_cmux_layout_action() {  # <layout> <N> -> split|tab|grid|window
  local layout=$1 n=$2 cap=${FM_CMUX_GRID_CAPACITY:-4}
  [ "$cap" -ge 1 ] 2>/dev/null || cap=4
  case "$layout" in
    splits) printf 'split\n' ;;
    # tabs: the first worker still opens a visible split to create the crew pane;
    # every later worker becomes a tab in it.
    tabs) [ "$n" -eq 0 ] && printf 'split\n' || printf 'tab\n' ;;
    # hybrid: the pre-grid default - split up to the threshold, then tab overflow.
    hybrid) [ "$n" -lt "$FM_CMUX_SPLIT_THRESHOLD" ] && printf 'split\n' || printf 'tab\n' ;;
    # auto: grid placement, overflowing to a new window each time the grid fills.
    *) if [ "$n" -gt 0 ] && [ $((n % cap)) -eq 0 ]; then printf 'window\n'; else printf 'grid\n'; fi ;;
  esac
}

# Grid slot for the new worker at existing-count N: which direction to split and
# what to anchor on. Pure arithmetic (column-major over FM_CMUX_GRID_ROWS rows,
# FM_CMUX_GRID_CAPACITY per grid), so it is unit-testable without cmux. Prints
# "<direction> <anchor>" where <anchor> is "caller" (split off firstmate's own
# surface, only the very first worker) or a 0-based creation-order index into the
# existing worker surfaces (see fm_terminal_cmux_worker_slots).
fm_terminal_cmux_grid_slot() {  # <N> -> "<left|right|up|down> <caller|index>"
  local n=$1 cap=${FM_CMUX_GRID_CAPACITY:-4} rows=${FM_CMUX_GRID_ROWS:-2} p g col row
  [ "$cap" -ge 1 ] 2>/dev/null || cap=4
  [ "$rows" -ge 1 ] 2>/dev/null || rows=2
  p=$((n % cap)); g=$((n / cap)); col=$((p / rows)); row=$((p % rows))
  if [ "$row" -eq 0 ]; then
    # Top of a column: open the column with a rightward split. The very first
    # worker (p==0, g==0) splits off firstmate; a later column's top splits off
    # the top worker of the previous column in this same grid.
    if [ "$p" -eq 0 ]; then
      printf 'right caller\n'
    else
      printf 'right %d\n' $((g * cap + (col - 1) * rows))
    fi
  else
    # Lower cell in a column: split down off the worker directly above it, which
    # is always the immediately-preceding worker (index N-1).
    printf 'down %d\n' $((n - 1))
  fi
}

# Ordered existing cmux worker (workspace, surface) pairs in creation order,
# excluding <exclude-id>. Creation order is the numeric surface ref, which cmux
# assigns monotonically per session (a later worker gets a higher number), so it
# is stable across meta appends (unlike file mtime) and across windows (surface
# refs are global). One "<workspace>\t<surface>" per line; workspace may be empty
# when a meta recorded none, in which case the caller falls back to its own
# workspace. This is the anchor source for grid placement.
fm_terminal_cmux_worker_slots() {  # <exclude-id>
  local exclude=$1 state=${STATE:?STATE required} meta base surface workspace
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    base=$(basename "$meta" .meta)
    [ "$base" = "$exclude" ] && continue
    [ "$(fm_terminal_meta_value "$meta" terminal_backend)" = cmux ] || continue
    surface=$(fm_terminal_meta_value "$meta" surface)
    [ -n "$surface" ] || continue
    workspace=$(fm_terminal_meta_value "$meta" workspace)
    printf '%s\t%s\t%s\n' "${surface#surface:}" "$workspace" "$surface"
  done | sort -t"$(printf '\t')" -k1,1n | cut -f2,3
}

# The pane a tab-overflow worker should stack into: the pane of the most recently
# spawned cmux worker, so overflow lands in an existing worker pane. Empty (rc 1)
# when no such pane is recorded, letting the caller fall back to a split. A cmux
# secondmate counts like any other cmux worker (Phase B slice 3), so its pane is a
# valid overflow target too.
fm_terminal_cmux_overflow_pane() {  # <exclude-id> -> pane:N
  local exclude=$1 state=${STATE:?STATE required} meta base pane newest='' newest_pane=''
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    base=$(basename "$meta" .meta)
    [ "$base" = "$exclude" ] && continue
    [ "$(fm_terminal_meta_value "$meta" terminal_backend)" = cmux ] || continue
    pane=$(fm_terminal_meta_value "$meta" pane)
    [ -n "$pane" ] || continue
    if [ -z "$newest" ] || [ "$meta" -nt "$newest" ]; then
      newest=$meta; newest_pane=$pane
    fi
  done
  [ -n "$newest_pane" ] || return 1
  printf '%s\n' "$newest_pane"
}

# Split off firstmate's own caller surface (or a fresh right-pane when there is
# no caller surface). Used by the splits/tabs/hybrid first-worker path and as the
# grid's caller/fallback anchor. Echoes cmux output; --focus false never steals
# focus.
fm_terminal_cmux_split_off_caller() {  # <workspace> <caller_surface> <direction>
  local ws=$1 caller_surface=$2 dir=${3:-right}
  if [ -n "$caller_surface" ]; then
    cmux new-split "$dir" --workspace "$ws" --surface "$caller_surface" --focus false 2>&1
  else
    cmux new-pane --type terminal --direction "$dir" --workspace "$ws" --focus false 2>&1
  fi
}

# Grid placement for the new worker at existing-count N: resolve the direction and
# anchor from grid_slot, then split off the anchor worker's own surface/workspace
# (so a later column and a later window both split off the correct prior worker).
# Falls back to splitting off firstmate if the anchor cannot be resolved.
fm_terminal_cmux_place_grid() {  # <workspace> <caller_surface> <exclude-id> <N>
  local ws=$1 caller_surface=$2 exclude=$3 n=$4 slot dir anchor line anchor_ws anchor_surface
  slot=$(fm_terminal_cmux_grid_slot "$n")
  dir=${slot%% *}; anchor=${slot##* }
  if [ "$anchor" = caller ]; then
    fm_terminal_cmux_split_off_caller "$ws" "$caller_surface" "$dir"
    return
  fi
  line=$(fm_terminal_cmux_worker_slots "$exclude" | sed -n "$((anchor + 1))p")
  anchor_ws=$(printf '%s' "$line" | cut -f1)
  anchor_surface=$(printf '%s' "$line" | cut -f2)
  if [ -z "$anchor_surface" ]; then
    fm_terminal_cmux_split_off_caller "$ws" "$caller_surface" "$dir"
    return
  fi
  [ -n "$anchor_ws" ] || anchor_ws=$ws
  cmux new-split "$dir" --workspace "$anchor_ws" --surface "$anchor_surface" --focus false 2>&1
}

# Overflow to a NEW cmux window. `cmux new-window` prints a bare "OK <uuid>" (NOT
# a "window:N" short ref like every other placement command here), so capture the
# raw handle rather than grepping for a short ref that will never appear. It also
# auto-creates a default workspace + terminal surface in the new window and takes
# focus there - the one placement command with no --focus flag - so the correct
# follow-up is `cmux identify`, which resolves that now-focused window's
# auto-created workspace/surface directly. Do not call `cmux new-workspace`/
# `cmux new-pane` here: that would create a SECOND, unwanted workspace/surface on
# top of the one new-window already made, and an accidentally empty --window arg
# on new-workspace silently retargets the current/live window instead of the new
# one. Echoes a single normalized "<surface:N> <workspace:N>" line so the caller
# captures BOTH the new surface and the new window's workspace (which differs
# from firstmate's).
fm_terminal_cmux_place_new_window() {
  local win_out win ident_out ws surface
  win_out=$(cmux new-window 2>&1) || { printf '%s\n' "$win_out" >&2; return 1; }
  win=$(printf '%s\n' "$win_out" | tail -1 | awk '{print $NF}')
  [ -n "$win" ] || { echo "error: cmux new-window did not report a window ref: $win_out" >&2; return 1; }
  ident_out=$(cmux identify --json 2>&1) || { printf '%s\n' "$ident_out" >&2; return 1; }
  ws=$(printf '%s\n' "$ident_out" | grep -o 'workspace:[0-9][0-9]*' | tail -1 || true)
  [ -n "$ws" ] || { echo "error: cmux identify did not report a workspace ref for new window $win: $ident_out" >&2; return 1; }
  surface=$(printf '%s\n' "$ident_out" | grep -o 'surface:[0-9][0-9]*' | tail -1 || true)
  [ -n "$surface" ] || { echo "error: cmux identify did not report a surface ref for new window $win: $ident_out" >&2; return 1; }
  printf '%s %s\n' "$surface" "$ws"
}

# Create the worker surface per the resolved layout and echo cmux's output so the
# caller can grep out surface:N (and, for the new-window path, workspace:N). Never
# steals focus. splits/tabs/hybrid keep their pre-grid shapes; auto tiles a grid
# and overflows to a new window when the grid is full.
fm_terminal_cmux_place_worker() {  # <workspace> <caller_surface> <layout> <exclude-id>
  local ws=$1 caller_surface=$2 layout=$3 exclude=$4 n action pane
  n=$(fm_terminal_cmux_worker_count "$exclude") || return 1
  action=$(fm_terminal_cmux_layout_action "$layout" "$n")
  if [ "$action" = tab ]; then
    pane=$(fm_terminal_cmux_overflow_pane "$exclude") || action='split'
  fi
  case "$action" in
    tab)    cmux new-surface --type terminal --pane "$pane" --workspace "$ws" --focus false 2>&1 ;;
    grid)   fm_terminal_cmux_place_grid "$ws" "$caller_surface" "$exclude" "$n" ;;
    window) fm_terminal_cmux_place_new_window ;;
    *)      fm_terminal_cmux_split_off_caller "$ws" "$caller_surface" right ;;
  esac
}

fm_terminal_target_meta() {  # <target> -> meta path or empty
  case "$1" in
    fm-*) printf '%s/%s.meta\n' "${STATE:?STATE required}" "${1#fm-}" ;;
  esac
}

fm_terminal_target_backend() {  # <target> -> tmux|cmux
  local meta
  case "$1" in
    *:*) printf 'tmux\n'; return 0 ;;
    fm-*)
      meta=$(fm_terminal_target_meta "$1")
      [ -f "$meta" ] || { echo "error: no metadata for $1 in $STATE; pass session:window to target a tmux window outside this firstmate home" >&2; return 1; }
      fm_terminal_meta_value "$meta" terminal_backend | grep -q . && fm_terminal_meta_value "$meta" terminal_backend || printf 'tmux\n'
      ;;
    *) printf 'tmux\n' ;;
  esac
}

fm_terminal_resolve_tmux() {  # <target> -> session:window
  local meta window
  case "$1" in
    *:*) echo "$1" ;;
    fm-*)
      meta=$(fm_terminal_target_meta "$1")
      [ -f "$meta" ] || { echo "error: no metadata for $1 in $STATE; pass session:window to target a window outside this firstmate home" >&2; return 1; }
      window=$(fm_terminal_meta_value "$meta" window)
      [ -n "$window" ] || { echo "error: no tmux window recorded in $meta" >&2; return 1; }
      echo "$window"
      ;;
    *) tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$1\$" \
         || { echo "error: no window named $1" >&2; return 1; } ;;
  esac
}

fm_terminal_cmux_workspace() {  # <fm-target>
  local meta ws
  meta=$(fm_terminal_target_meta "$1")
  ws=$(fm_terminal_meta_value "$meta" workspace)
  [ -n "$ws" ] || { echo "error: no cmux workspace recorded in $meta" >&2; return 1; }
  printf '%s\n' "$ws"
}

fm_terminal_cmux_surface() {  # <fm-target>
  local meta surface
  meta=$(fm_terminal_target_meta "$1")
  surface=$(fm_terminal_meta_value "$meta" surface)
  [ -n "$surface" ] || { echo "error: no cmux surface recorded in $meta" >&2; return 1; }
  printf '%s\n' "$surface"
}

fm_terminal_send_key() {  # <target> <key>
  local target=$1 key=$2 backend t ws surface
  backend=$(fm_terminal_target_backend "$target") || return 1
  case "$backend" in
    cmux)
      case "$key" in
        C-c) key='ctrl+c' ;;
        C-d) key='ctrl+d' ;;
      esac
      ws=$(fm_terminal_cmux_workspace "$target") || return 1
      surface=$(fm_terminal_cmux_surface "$target") || return 1
      cmux send-key --workspace "$ws" --surface "$surface" "$key"
      ;;
    *)
      t=$(fm_terminal_resolve_tmux "$target") || return 1
      tmux send-keys -t "$t" "$key"
      ;;
  esac
}

fm_terminal_read() {  # <target> <lines>
  local target=$1 lines=${2:-40} backend t ws surface
  backend=$(fm_terminal_target_backend "$target") || return 1
  case "$backend" in
    cmux)
      ws=$(fm_terminal_cmux_workspace "$target") || return 1
      surface=$(fm_terminal_cmux_surface "$target") || return 1
      cmux read-screen --workspace "$ws" --surface "$surface" --lines "$lines"
      ;;
    *)
      t=$(fm_terminal_resolve_tmux "$target") || return 1
      tmux capture-pane -p -t "$t" -S -"$lines"
      ;;
  esac
}

fm_terminal_busy() {  # <target>
  local backend tail40 t
  backend=$(fm_terminal_target_backend "$1") || return 1
  case "$backend" in
    cmux)
      tail40=$(fm_terminal_read "$1" 40 2>/dev/null) || return 1
      printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
        | grep -qiE "${FM_BUSY_REGEX:-$FM_TERMINAL_BUSY_REGEX_DEFAULT}"
      ;;
    *)
      t=$(fm_terminal_resolve_tmux "$1") || return 1
      fm_pane_is_busy "$t"
      ;;
  esac
}

fm_terminal_close() {  # <target>
  local backend t ws surface close_out
  backend=$(fm_terminal_target_backend "$1") || return 1
  case "$backend" in
    cmux)
      ws=$(fm_terminal_cmux_workspace "$1") || return 1
      surface=$(fm_terminal_cmux_surface "$1") || return 1
      close_out=$(cmux close-surface --workspace "$ws" --surface "$surface" 2>&1) && return 0
      # If the process already exited, cmux may already have removed the surface.
      # Treat that as closed. If this is the last surface in its pane, ask the
      # terminal shell to exit instead; cmux will remove the dead surface/pane.
      case "$close_out" in
        *'not_found'*|*'Surface not found'*) return 0 ;;
        *'Cannot close the last surface'*) cmux send-key --workspace "$ws" --surface "$surface" 'ctrl+d' >/dev/null 2>&1 || true; return 0 ;;
      esac
      printf '%s\n' "$close_out" >&2
      return 1
      ;;
    *)
      t=$(fm_terminal_resolve_tmux "$1") || return 1
      tmux kill-window -t "$t" 2>/dev/null || true
      ;;
  esac
}
