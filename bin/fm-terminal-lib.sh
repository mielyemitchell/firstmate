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
