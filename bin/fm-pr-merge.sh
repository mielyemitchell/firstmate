#!/usr/bin/env bash
# Merge a task's PR, always recording pr= and any available pr_head= into
# state/<id>.meta first via bin/fm-pr-check.sh, so bin/fm-teardown.sh's
# landed-check has a PR reference to verify a squash merge against.
#
# Why this exists: the normal trigger for running fm-pr-check.sh is the crew's
# `done: PR <url> checks green` line, which no-mistakes only emits once its CI
# step turns green. Repos that intentionally run no CI on PRs (CI only on
# pushes to the default branch) never emit that line, so a merge performed by
# hand-running `gh-axi pr merge` - the common shape of a yolo-authorized merge -
# can skip the recording step entirely. Teardown then has nothing to look up for
# a squash-merge-then-delete-branch flow and false-refuses provably landed work.
# This script makes recording part of the merge itself, so it cannot be skipped
# by omission. Use it for every PR merge (captain-requested or yolo-authorized),
# in place of calling `gh-axi pr merge` directly.
#
# gh-axi pr merge expects a PR number and --repo <owner>/<repo>; it does not
# parse a full https://github.com/<owner>/<repo>/pull/<n> URL. This script
# parses the URL and invokes gh-axi in the form it accepts.
#
# Merge method: defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. An explicit
# caller method is never overridden.
# Extra args must not include --repo or -R because the repo is parsed from the
# PR URL.
#
# CI guard: records PR metadata first, then refuses to merge unless the PR check
# rollup is green.
# A PR with no checks configured is allowed; pending, failing, canceled, or
# unknown check states are refused without an override flag.
#
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ID=${1:?usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]}
URL=${2:?usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]}
shift 2
[ "${1:-}" = "--" ] && shift

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META; refusing to merge without recording pr=" >&2; exit 1; }

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

parse_pr_url() {
  local url=$1
  if [[ "$url" =~ ^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]+)/pull/([0-9]+)/?$ ]]; then
    PR_OWNER="${BASH_REMATCH[1]}"
    PR_REPO="${BASH_REMATCH[2]}"
    PR_NUMBER="${BASH_REMATCH[3]}"
    if [[ "$PR_OWNER" != *- ]]; then
      return 0
    fi
  fi
  echo "error: PR URL must match https://github.com/<owner>/<repo>/pull/<number> (got: $url)" >&2
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge args must not override --repo parsed from PR URL (got: $arg)" >&2
        return 1
        ;;
    esac
  done
  return 0
}

checks_output_means_no_checks() {
  local output=$1
  [ -z "$output" ] && return 0
  case "$output" in
    *"no checks"*|*"No checks"*|*"no check runs"*|*"No check runs"*|*"no CI checks configured"*) return 0 ;;
  esac
  return 1
}

check_summary_from_json() {
  local output=$1 bad
  [ "$output" = "[]" ] && return 0
  checks_output_means_no_checks "$output" && return 0
  if printf '%s\n' "$output" | grep -Eq '"bucket"[[:space:]]*:[[:space:]]*"fail"'; then
    printf '%s\n' "fail"
    return 1
  fi
  if printf '%s\n' "$output" | grep -Eq '"bucket"[[:space:]]*:[[:space:]]*"pending"'; then
    printf '%s\n' "pending"
    return 1
  fi
  if printf '%s\n' "$output" | grep -Eq '"bucket"[[:space:]]*:[[:space:]]*"cancel"'; then
    printf '%s\n' "cancel"
    return 1
  fi
  bad=$(printf '%s\n' "$output" | tr -d '\n' | sed -n 's/.*"bucket"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  case "$bad" in
    pass|skipping) return 0 ;;
    "") printf '%s\n' "unknown"; return 1 ;;
    *) printf '%s\n' "$bad"; return 1 ;;
  esac
}

check_summary_from_text() {
  local output=$1 summary_line failed pending
  checks_output_means_no_checks "$output" && return 0
  # gh-axi's primary check output is a fixed "summary: \"X passed, Y failed,
  # [Z skipped,] [W pending,] N total\"" line, with per-check "name,conclusion"
  # rows in a separate section below it. Read counts only off that summary
  # line so a check/job named e.g. "cancel-previous-runs" or "fail-fast"
  # can never be mistaken for an actual failing/pending/cancelled state.
  summary_line=$(printf '%s\n' "$output" | grep -m1 -E '^summary:')
  if [ -z "$summary_line" ]; then
    printf '%s\n' "unknown"
    return 1
  fi
  failed=$(printf '%s\n' "$summary_line" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) failed.*/\1/p')
  pending=$(printf '%s\n' "$summary_line" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) pending.*/\1/p')
  failed=${failed:-0}
  pending=${pending:-0}
  if [ "$failed" -gt 0 ]; then
    printf '%s\n' "fail"
    return 1
  fi
  if [ "$pending" -gt 0 ]; then
    printf '%s\n' "pending"
    return 1
  fi
  return 0
}

gh_axi_checks_needs_fallback() {
  local rc=$1 output=$2
  [ "$rc" -eq 0 ] && return 1
  case "$output" in
    *"unknown flag: --repo"*|*"unknown flag: repo"*|*"Usage:"*|*"usage:"*) return 0 ;;
  esac
  return 1
}

assert_no_cancelled_checks() {
  local repo=$1 output rc
  if ! command -v gh >/dev/null 2>&1; then
    echo "error: checks not green: cannot verify checks are not cancelled without gh; refusing to merge $URL" >&2
    return 1
  fi
  set +e
  output=$(gh pr checks "$PR_NUMBER" --repo "$repo" --json name,bucket,state 2>&1)
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "error: checks not green: unable to verify checks are not cancelled ($output); refusing to merge $URL" >&2
    return 1
  fi
  if printf '%s\n' "$output" | grep -Eq '"bucket"[[:space:]]*:[[:space:]]*"cancel"'; then
    echo "error: checks not green: cancel; refusing to merge $URL" >&2
    return 1
  fi
  return 0
}

assert_pr_checks_green() {
  local repo=$1 output rc state
  set +e
  output=$(gh-axi pr checks "$PR_NUMBER" --repo "$repo" 2>&1)
  rc=$?
  set -e
  if gh_axi_checks_needs_fallback "$rc" "$output"; then
    set +e
    output=$(gh pr checks "$PR_NUMBER" --repo "$repo" --json name,bucket,state 2>&1)
    rc=$?
    set -e
    if state=$(check_summary_from_json "$output"); then
      return 0
    fi
    echo "error: checks not green: $state; refusing to merge $URL" >&2
    return 1
  fi
  if ! state=$(check_summary_from_text "$output"); then
    echo "error: checks not green: $state; refusing to merge $URL" >&2
    return 1
  fi
  if checks_output_means_no_checks "$output"; then
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    echo "error: checks not green: unknown; refusing to merge $URL" >&2
    return 1
  fi
  # gh-axi's own classification buckets a CANCELLED conclusion into the same
  # "skip" category as a normal conditional skip, so its summary/per-check
  # output cannot distinguish the two. Only the real `gh` CLI's bucket field
  # separates "cancel" from "skipping", so that is the authoritative source
  # for this specific check.
  assert_no_cancelled_checks "$repo"
}

parse_pr_url "$URL" || exit 1
reject_repo_overrides "$@" || exit 1

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || { echo "error: fm-pr-check did not record pr=$URL in $META; refusing to merge" >&2; exit 1; }
assert_pr_checks_green "$PR_OWNER/$PR_REPO" || exit 1

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" ${merge_args[@]+"${merge_args[@]}"} "$@"
