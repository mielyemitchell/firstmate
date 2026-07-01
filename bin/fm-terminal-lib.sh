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
# already has. Mielye default (auto): the 1st..3rd workers each get their own
# visible split so they are watchable at once; the 4th and later workers overflow
# to a tab (extra surface) in an existing worker pane instead of an unbounded pile
# of splits. Explicit config/cmux-layout values force one shape.
#
# FM_CMUX_SPLIT_THRESHOLD is the max number of EXISTING workers that still get a
# split under auto/hybrid: a new worker splits while count < threshold and
# overflows to a tab once count >= threshold (so with 3, workers 1-3 split and
# worker 4+ tabs). Named so it is obvious and tunable.
FM_CMUX_SPLIT_THRESHOLD=${FM_CMUX_SPLIT_THRESHOLD:-3}

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

# Decide placement for a new worker: split (own visible pane) or tab (overflow
# surface). N is the existing cmux worker count.
fm_terminal_cmux_layout_action() {  # <layout> <N> -> split|tab
  local layout=$1 n=$2
  case "$layout" in
    splits) printf 'split\n' ;;
    # tabs: the first worker still opens a visible split to create the crew pane;
    # every later worker becomes a tab in it.
    tabs) [ "$n" -eq 0 ] && printf 'split\n' || printf 'tab\n' ;;
    # hybrid and auto share the Mielye default: split up to the threshold, then tab.
    *) [ "$n" -lt "$FM_CMUX_SPLIT_THRESHOLD" ] && printf 'split\n' || printf 'tab\n' ;;
  esac
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

# Create the worker surface per the resolved layout and echo cmux's output so the
# caller can grep out surface:N. Runs exactly one cmux command (never steals focus)
# and returns its exit status. Split uses new-split off the caller surface (or a
# new-pane when there is no caller surface); tab overflow uses new-surface in an
# existing worker pane, falling back to a split when no such pane exists yet.
fm_terminal_cmux_place_worker() {  # <workspace> <caller_surface> <layout> <exclude-id>
  local ws=$1 caller_surface=$2 layout=$3 exclude=$4 n action pane
  n=$(fm_terminal_cmux_worker_count "$exclude") || return 1
  action=$(fm_terminal_cmux_layout_action "$layout" "$n")
  if [ "$action" = tab ]; then
    pane=$(fm_terminal_cmux_overflow_pane "$exclude") || action='split'
  fi
  if [ "$action" = tab ]; then
    cmux new-surface --type terminal --pane "$pane" --workspace "$ws" --focus false 2>&1
  elif [ -n "$caller_surface" ]; then
    cmux new-split right --workspace "$ws" --surface "$caller_surface" --focus false 2>&1
  else
    cmux new-pane --type terminal --direction right --workspace "$ws" --focus false 2>&1
  fi
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
