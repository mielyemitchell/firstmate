#!/usr/bin/env bash
# fm-landed-work-lib.sh - conservative landed-work assessment shared by cleanup tools.
#
# The safety contract mirrors fm-teardown.sh: uncommitted changes are never
# landed, commits reachable from any remote-tracking branch are landed, and
# local-only work may also be landed on the local default branch.
#
# Task kind carve-outs also mirror fm-teardown.sh. A kind=secondmate record is
# never assessed as cleanable here: secondmate retirement is an explicit,
# captain/firstmate-gated decision (AGENTS.md section 7) with its own in-flight
# check and registry removal that this shared assessor cannot perform, so it
# always reports blocked and points at bin/fm-teardown.sh. A kind=scout
# worktree is deliberately left dirty/scratch; teardown's carve-out ignores its
# dirty/unpushed state entirely and gates only on the report existing, so this
# assessor does the same.

fm_landed_default_branch() {  # <repo>
  local repo=$1 ref branch
  ref=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

fm_landed_content_in_default() {  # <worktree> <project>
  local wt=$1 project=$2 name ref default_tree merged_tree
  name=$(fm_landed_default_branch "$project") || return 1
  if git -C "$wt" remote get-url origin >/dev/null 2>&1; then
    git -C "$wt" fetch --quiet origin "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1 || return 1
    ref="refs/remotes/origin/$name"
  elif git -C "$wt" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    ref="refs/heads/$name"
  else
    return 1
  fi
  default_tree=$(git -C "$wt" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$default_tree" ] || return 1
  merged_tree=$(git -C "$wt" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || return 1
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  [ "$merged_tree" = "$default_tree" ]
}

fm_landed_assess_worktree() {  # <worktree> <project> <mode> [<kind>] [<report>]
  local wt=$1 project=$2 mode=${3:-no-mistakes} kind=${4:-ship} report=${5:-}
  local dirty_raw dirty unpushed_raw unpushed default unmerged_raw unmerged

  if [ "$kind" = secondmate ]; then
    printf 'blocked\tsecondmate retirement is an explicit decision; use bin/fm-teardown.sh, not stale-state cleanup\n'
    return 1
  fi

  if [ "$kind" = scout ]; then
    if [ -n "$report" ] && [ -f "$report" ]; then
      printf 'landed\tscout report present at %s\n' "$report"
      return 0
    fi
    printf 'unlanded\tscout report not yet written at %s\n' "${report:-<unknown>}"
    return 1
  fi

  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    printf 'landed\tno inspectable worktree path recorded\n'
    return 0
  fi
  if ! git -C "$wt" rev-parse --show-toplevel >/dev/null 2>&1; then
    printf 'blocked\tworktree is not an inspectable git worktree: %s\n' "$wt"
    return 1
  fi
  [ -n "$project" ] || project=$wt

  if ! dirty_raw=$(git -C "$wt" status --porcelain 2>/dev/null); then
    printf 'blocked\tcannot inspect worktree for uncommitted changes: %s\n' "$wt"
    return 1
  fi
  dirty=$(printf '%s\n' "$dirty_raw" | grep -vE '^\?\? (\.claude/|\.fm-grok-turnend$)' | head -1 || true)
  if [ -n "$dirty" ]; then
    printf 'unlanded\tuncommitted changes present\n'
    return 1
  fi

  if ! unpushed_raw=$(git -C "$wt" log --oneline HEAD --not --remotes -- 2>/dev/null); then
    printf 'blocked\tcannot inspect worktree for commits not reachable from remotes: %s\n' "$wt"
    return 1
  fi
  unpushed=$(printf '%s\n' "$unpushed_raw" | head -5)
  if [ -z "$unpushed" ]; then
    printf 'landed\tall commits reachable from a remote-tracking branch\n'
    return 0
  fi

  if [ "$mode" = local-only ]; then
    default=$(fm_landed_default_branch "$project") || {
      printf 'blocked\tcannot determine default branch for %s\n' "$project"
      return 1
    }
    if ! unmerged_raw=$(git -C "$wt" log --oneline HEAD --not "$default" -- 2>/dev/null); then
      printf 'blocked\tcannot inspect commits not on %s\n' "$default"
      return 1
    fi
    unmerged=$(printf '%s\n' "$unmerged_raw" | head -5)
    if [ -z "$unmerged" ]; then
      printf 'landed\tlocal-only work merged into %s\n' "$default"
      return 0
    fi
    printf 'unlanded\tcommits not on any remote or %s: %s\n' "$default" "$(printf '%s' "$unmerged" | tr '\n' ';')"
    return 1
  fi

  if fm_landed_content_in_default "$wt" "$project"; then
    printf 'landed\tbranch content already present in default branch\n'
    return 0
  fi
  printf 'unlanded\tcommits not reachable from any remote and not present in default branch: %s\n' "$(printf '%s' "$unpushed" | tr '\n' ';')"
  return 1
}
