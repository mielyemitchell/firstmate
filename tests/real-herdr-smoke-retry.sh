#!/usr/bin/env bash
# Shared whole-script retry for real-herdr smoke tests that exercise
# bin/fm-spawn.sh's real treehouse acquisition path.
#
# These tests are intentionally end-to-end, so the least invasive flake
# handling is at the test-process boundary: retry only when fm-spawn.sh reports
# the exact environmental signature where `treehouse get` never moved the pane
# into a worktree. All other failures surface immediately, and deterministic
# regressions still fail after the bounded retry count.
set -u

fm_real_herdr_smoke_retry_on_treehouse_contention() {
  [ -z "${FM_REAL_HERDR_SMOKE_ATTEMPT:-}" ] || return 0

  local attempts=${FM_REAL_HERDR_SMOKE_RETRIES:-3}
  local tmp attempt rc combined
  tmp=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-real-herdr-smoke-retry.XXXXXX") || exit 1

  attempt=1
  while [ "$attempt" -le "$attempts" ]; do
    FM_REAL_HERDR_SMOKE_ATTEMPT=$attempt "$BASH" "$0" "$@" >"$tmp/out" 2>"$tmp/err"
    rc=$?
    cat "$tmp/out"
    cat "$tmp/err" >&2
    [ "$rc" -eq 0 ] && { rm -rf "$tmp"; exit 0; }

    combined=$(cat "$tmp/out" "$tmp/err")
    case "$combined" in
      *"error: treehouse get did not enter a worktree within 60s; inspect window "*)
        if [ "$attempt" -lt "$attempts" ]; then
          printf 'retry: real-herdr smoke hit treehouse lease contention signature (attempt %s/%s); retrying\n' "$attempt" "$attempts" >&2
          attempt=$((attempt + 1))
          sleep 2
          continue
        fi
        ;;
    esac

    rm -rf "$tmp"
    exit "$rc"
  done
}
