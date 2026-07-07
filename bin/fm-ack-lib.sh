#!/usr/bin/env bash
# Shared pending-ack helpers for fm-send.sh and fm-watch.sh.
#
# File format: state/.pending-acks is one tab-separated row per pending send:
#   id<TAB>sent_at<TAB>deadline<TAB>pre_status_sig<TAB>pre_status_lines<TAB>escalated<TAB>summary
# The target id is stored without the fm- prefix.
# The summary is sanitized to avoid tabs/newlines and starts with a short digest.

fm_ack_stat_sig() {  # <path>
  if [ ! -e "$1" ]; then
    printf '-'
    return 0
  fi
  if [ "$(uname)" = Darwin ]; then
    stat -f '%z:%Fm' "$1" 2>/dev/null || printf '-'
  else
    stat -c '%s:%Y' "$1" 2>/dev/null || printf '-'
  fi
}

fm_ack_mtime() {  # <path>
  if [ ! -e "$1" ]; then
    printf '0'
    return 0
  fi
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null || printf '0'
  else
    stat -c %Y "$1" 2>/dev/null || printf '0'
  fi
}

fm_ack_line_count() {  # <path>
  if [ ! -e "$1" ]; then
    printf '0'
    return 0
  fi
  wc -l < "$1" 2>/dev/null | tr -d '[:space:]'
}

fm_ack_hash() {
  if command -v md5 >/dev/null 2>&1; then
    md5 -q
  else
    md5sum | cut -d' ' -f1
  fi
}

fm_ack_lock_acquire() {  # <state>
  local state=$1 lock i
  lock="$state/.pending-acks.lock"
  i=0
  while ! mkdir "$lock" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 50 ] || return 1
    sleep 0.1
  done
  printf '%s\n' "$$" > "$lock/pid" 2>/dev/null || true
  FM_ACK_LOCK_HELD=$lock
  return 0
}

fm_ack_lock_release() {
  local lock=${FM_ACK_LOCK_HELD:-}
  [ -n "$lock" ] || return 0
  rm -f "$lock/pid" 2>/dev/null || true
  rmdir "$lock" 2>/dev/null || true
  FM_ACK_LOCK_HELD=
}

fm_ack_summary() {  # <message>
  local msg=$1 clean digest preview
  digest=$(printf '%s' "$msg" | fm_ack_hash | cut -c1-12)
  clean=$(printf '%s' "$msg" | tr '\t\r\n|' '    ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')
  preview=$(printf '%s' "$clean" | cut -c1-80)
  if [ -n "$preview" ]; then
    printf '%s %s' "$digest" "$preview"
  else
    printf '%s <empty>' "$digest"
  fi
}

fm_ack_record() {  # <state> <id> <sent-at> <deadline> <pre-sig> <pre-lines> <message>
  local state=$1 id=$2 sent_at=$3 deadline=$4 pre_sig=$5 pre_lines=$6 msg=$7 file summary rc
  file="$state/.pending-acks"
  summary=$(fm_ack_summary "$msg")
  mkdir -p "$state"
  fm_ack_lock_acquire "$state" || return 1
  if printf '%s\t%s\t%s\t%s\t%s\t0\t%s\n' "$id" "$sent_at" "$deadline" "$pre_sig" "$pre_lines" "$summary" >> "$file"; then
    rc=0
  else
    rc=1
  fi
  fm_ack_lock_release
  return "$rc"
}

fm_ack_status_changed_after_send() {  # <state> <id> <sent-at> <pre-sig> <pre-lines>
  local state=$1 id=$2 sent_at=$3 pre_sig=$4 pre_lines=$5 status sig lines mtime
  status="$state/$id.status"
  [ -e "$status" ] || return 1
  sig=$(fm_ack_stat_sig "$status")
  lines=$(fm_ack_line_count "$status")
  mtime=$(fm_ack_mtime "$status")
  case "$mtime" in ''|*[!0-9]*) mtime=0 ;; esac
  case "$lines" in ''|*[!0-9]*) lines=0 ;; esac
  case "$pre_lines" in ''|*[!0-9]*) pre_lines=0 ;; esac
  [ "$sig" != "$pre_sig" ] && return 0
  [ "$lines" -gt "$pre_lines" ] && return 0
  [ "$mtime" -gt "$sent_at" ] && return 0
  return 1
}

fm_ack_late_label() {  # <seconds>
  local late=$1 mins
  case "$late" in ''|*[!0-9]*) late=0 ;; esac
  if [ "$late" -ge 120 ]; then
    mins=$((late / 60))
    printf '%sm%ss' "$mins" "$((late % 60))"
  else
    printf '%ss' "$late"
  fi
}

fm_ack_scan_pending() {  # <state> [now]
  local state=$1 now=${2:-$(date +%s)} file tmp any id sent_at deadline pre_sig pre_lines escalated summary late label reason rc
  file="$state/.pending-acks"
  [ -e "$file" ] || return 1
  fm_ack_lock_acquire "$state" || return 1
  tmp="$file.tmp.$$"
  any=
  : > "$tmp" || { fm_ack_lock_release; return 1; }
  while IFS=$(printf '\t') read -r id sent_at deadline pre_sig pre_lines escalated summary; do
    [ -n "$id" ] || continue
    if fm_ack_status_changed_after_send "$state" "$id" "$sent_at" "$pre_sig" "$pre_lines"; then
      continue
    fi
    case "$deadline" in ''|*[!0-9]*) deadline=0 ;; esac
    if [ "$now" -ge "$deadline" ] && [ "$escalated" != 1 ]; then
      late=$((now - deadline))
      label=$(fm_ack_late_label "$late")
      reason="ack-missed: fm-$id did not acknowledge within deadline (${label} late): $summary"
      if command -v fm_wake_append >/dev/null 2>&1; then
        fm_wake_append signal "$id.ack" "$reason" || { rm -f "$tmp"; fm_ack_lock_release; return 1; }
      fi
      printf '%s\t%s\t%s\t%s\t%s\t1\t%s\n' "$id" "$sent_at" "$deadline" "$pre_sig" "$pre_lines" "$summary" >> "$tmp"
      [ -n "$any" ] || any=$reason
    else
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$sent_at" "$deadline" "$pre_sig" "$pre_lines" "$escalated" "$summary" >> "$tmp"
    fi
  done < "$file"
  rc=0
  if [ -s "$tmp" ]; then
    mv -f "$tmp" "$file" || rc=1
  else
    rm -f "$tmp" "$file" || rc=1
  fi
  fm_ack_lock_release
  [ "$rc" = 0 ] || return 1
  [ -n "$any" ] || return 1
  printf '%s\n' "$any"
}
