#!/usr/bin/env bash
# Behavior tests for FM_HOME ownership checks.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-home-guard)
LOCK="$ROOT/bin/fm-lock.sh"

make_firstmate_home() {
  local home=$1 id=${2:-}
  mkdir -p "$home/bin" "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  cp "$ROOT/bin/fm-home-guard-lib.sh" "$home/bin/fm-home-guard-lib.sh"
  git -C "$home" init -q
  git -C "$home" add AGENTS.md bin/fm-home-guard-lib.sh
  git -C "$home" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  if [ -n "$id" ]; then
    printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  fi
}

test_secondmate_context_refuses_foreign_home_lock() {
  local primary secondmate out status
  primary="$TMP_ROOT/primary"
  secondmate="$TMP_ROOT/secondmate"
  make_firstmate_home "$primary"
  make_firstmate_home "$secondmate" lane-a

  set +e
  out=$(cd "$secondmate" && FM_HOME="$primary" "$LOCK" 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "foreign FM_HOME from secondmate context should fail before lock"
  assert_contains "$out" "refuses to mutate FM_HOME" "guard did not explain the refusal"
  assert_absent "$primary/state/.lock" "guard should refuse before touching the foreign lock"
  pass "secondmate context refuses to lock a foreign FM_HOME"
}

test_secondmate_context_allows_own_home_status() {
  local secondmate out status
  secondmate="$TMP_ROOT/secondmate-own"
  make_firstmate_home "$secondmate" lane-b

  set +e
  out=$(cd "$secondmate" && FM_HOME="$secondmate" "$LOCK" status 2>&1)
  status=$?
  set -e

  expect_code 0 "$status" "own FM_HOME status should remain allowed"
  assert_contains "$out" "lock: free" "own-home lock status changed"
  pass "secondmate context allows its own FM_HOME"
}

test_repo_root_with_scratch_home_keeps_working() {
  local home out status
  home="$TMP_ROOT/scratch-home"
  make_firstmate_home "$home"

  set +e
  out=$(FM_HOME="$home" "$LOCK" status 2>&1)
  status=$?
  set -e

  expect_code 0 "$status" "repo-root caller with explicit scratch FM_HOME should keep working"
  assert_contains "$out" "lock: free" "repo-root scratch status changed"
  assert_not_contains "$out" "refuses to mutate" "repo-root scratch flow should not trip secondmate guard"
  pass "repo-root scratch FM_HOME flow is unchanged"
}

test_secondmate_context_refuses_foreign_home_lock
test_secondmate_context_allows_own_home_status
test_repo_root_with_scratch_home_keeps_working

echo "# all fm-home-guard tests passed"
