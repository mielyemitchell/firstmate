#!/usr/bin/env bash
# tests/fm-reconcile-stale.test.sh - stale state reconciler behavior.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

RECONCILE="$ROOT/bin/fm-reconcile-stale.sh"
TMP_ROOT=$(fm_test_tmproot fm-reconcile-stale-tests)

make_fakebin() {  # <case-dir> <live|dead>
  local case_dir=$1 state=$2 fakebin
  fakebin=$(fm_fakebin "$case_dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message)
    if [ "${FM_FAKE_TMUX_LIVE:-0}" = 1 ]; then
      printf '%%1\n'
      exit 0
    fi
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  if [ "$state" = live ]; then
    printf '%s|1\n' "$fakebin"
  else
    printf '%s|0\n' "$fakebin"
  fi
}

make_git_world() {  # <case-dir>
  local case_dir=$1
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m baseline
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task "$case_dir/wt" main
}

make_case() {  # <name> <live|dead>
  local name=$1 endpoint_state=$2 case_dir rec fakebin live
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/home/state" "$case_dir/home/config" "$case_dir/home/data"
  make_git_world "$case_dir"
  rec=$(make_fakebin "$case_dir" "$endpoint_state")
  IFS='|' read -r fakebin live <<EOF
$rec
EOF
  fm_write_meta "$case_dir/home/state/task-a.meta" \
    "backend=tmux" \
    "window=fm-task-a" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "tasktmp=$case_dir/fm-task-a"
  printf 'working: old event\n' > "$case_dir/home/state/task-a.status"
  touch "$case_dir/home/state/task-a.turn-ended" "$case_dir/home/state/task-a.check.sh" "$case_dir/home/state/task-a.pi-ext.ts"
  mkdir -p "$case_dir/fm-task-a"
  printf 'temp\n' > "$case_dir/fm-task-a/file.txt"
  printf '%s|%s|%s\n' "$case_dir" "$fakebin" "$live"
}

state_fingerprint() {  # <state-dir>
  ( cd "$1" && find . -type f -print | sort | while IFS= read -r f; do shasum "$f"; done )
}

run_reconcile() {  # <case-dir> <fakebin> <live> [args...]
  local case_dir=$1 fakebin=$2 live=$3
  shift 3
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LIVE="$live" FM_HOME="$case_dir/home" "$RECONCILE" "$@"
}

test_dry_run_reports_stale_and_writes_nothing() {
  local rec case_dir fakebin live before after out
  rec=$(make_case dry-run dead)
  IFS='|' read -r case_dir fakebin live <<EOF
$rec
EOF
  before=$(state_fingerprint "$case_dir/home/state")
  out=$(run_reconcile "$case_dir" "$fakebin" "$live")
  after=$(state_fingerprint "$case_dir/home/state")

  assert_contains "$out" "FIRSTMATE STALE STATE RECONCILE DRY RUN" "dry run header missing"
  assert_contains "$out" "id=task-a kind=ship backend=tmux target=fm-task-a" "stale record missing"
  assert_contains "$out" "landed=landed" "landed assessment missing"
  assert_contains "$out" "No files were modified" "dry-run no-write note missing"
  [ "$before" = "$after" ] || fail "dry run modified state files"

  pass "fm-reconcile-stale.sh dry run reports stale records and writes nothing"
}

test_clean_without_yes_refuses_and_writes_nothing() {
  local rec case_dir fakebin live before after out rc=0
  rec=$(make_case no-yes dead)
  IFS='|' read -r case_dir fakebin live <<EOF
$rec
EOF
  before=$(state_fingerprint "$case_dir/home/state")
  out=$(run_reconcile "$case_dir" "$fakebin" "$live" --clean task-a 2>&1) || rc=$?
  after=$(state_fingerprint "$case_dir/home/state")

  expect_code 1 "$rc" "--clean without --yes"
  assert_contains "$out" "would remove:" "clean plan missing"
  assert_contains "$out" "REFUSED: --clean requires --yes" "missing --yes refusal"
  [ "$before" = "$after" ] || fail "--clean without --yes modified state files"

  pass "fm-reconcile-stale.sh --clean without --yes mutates nothing"
}

test_clean_refuses_unlanded_work() {
  local rec case_dir fakebin live out rc=0
  rec=$(make_case unlanded dead)
  IFS='|' read -r case_dir fakebin live <<EOF
$rec
EOF
  printf 'unlanded\n' > "$case_dir/wt/unlanded.txt"
  git -C "$case_dir/wt" add unlanded.txt
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q -m "unlanded"

  out=$(run_reconcile "$case_dir" "$fakebin" "$live" --clean task-a --yes 2>&1) || rc=$?

  expect_code 1 "$rc" "unlanded cleanup"
  assert_contains "$out" "landed=unlanded" "unlanded assessment missing"
  assert_contains "$out" "REFUSED: recorded work path may hold unlanded work" "unlanded refusal missing"
  assert_present "$case_dir/home/state/task-a.meta" "unlanded cleanup removed meta"

  pass "fm-reconcile-stale.sh refuses cleanup when work is unlanded"
}

test_clean_refuses_live_endpoint() {
  local rec case_dir fakebin live out rc=0
  rec=$(make_case live-endpoint live)
  IFS='|' read -r case_dir fakebin live <<EOF
$rec
EOF

  out=$(run_reconcile "$case_dir" "$fakebin" "$live" --clean task-a --yes 2>&1) || rc=$?

  expect_code 1 "$rc" "live endpoint cleanup"
  assert_contains "$out" "REFUSED: task task-a still has a live tmux endpoint" "live endpoint refusal missing"
  assert_present "$case_dir/home/state/task-a.meta" "live endpoint cleanup removed meta"

  pass "fm-reconcile-stale.sh refuses cleanup when endpoint is live"
}

test_clean_respects_fleet_freeze() {
  local rec case_dir fakebin live out rc=0
  rec=$(make_case frozen dead)
  IFS='|' read -r case_dir fakebin live <<EOF
$rec
EOF
  printf 'reason=test freeze\n' > "$case_dir/home/state/.fleet-freeze"

  out=$(run_reconcile "$case_dir" "$fakebin" "$live" --clean task-a --yes 2>&1) || rc=$?

  expect_code 1 "$rc" "frozen cleanup"
  assert_contains "$out" "fleet frozen" "freeze refusal missing"
  assert_present "$case_dir/home/state/task-a.meta" "frozen cleanup removed meta"

  pass "fm-reconcile-stale.sh refuses mutation while fleet is frozen"
}

test_clean_yes_removes_only_state_and_tasktmp() {
  local rec case_dir fakebin live out branch
  rec=$(make_case clean dead)
  IFS='|' read -r case_dir fakebin live <<EOF
$rec
EOF
  printf 'keep\n' > "$case_dir/home/state/other.status"

  out=$(run_reconcile "$case_dir" "$fakebin" "$live" --clean task-a --yes)
  branch=$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD)

  assert_contains "$out" "cleaned stale state for task-a" "clean success missing"
  assert_absent "$case_dir/home/state/task-a.meta" "meta survived clean"
  assert_absent "$case_dir/home/state/task-a.status" "status survived clean"
  assert_absent "$case_dir/home/state/task-a.turn-ended" "turn-ended survived clean"
  assert_absent "$case_dir/home/state/task-a.check.sh" "check survived clean"
  assert_absent "$case_dir/home/state/task-a.pi-ext.ts" "pi extension survived clean"
  assert_absent "$case_dir/fm-task-a" "tasktmp survived clean"
  assert_present "$case_dir/home/state/other.status" "unrelated state file was removed"
  assert_present "$case_dir/wt/.git" "worktree was removed"
  assert_present "$case_dir/project/.git" "project clone was removed"
  [ "$branch" = "fm/task" ] || fail "cleanup changed branch"

  pass "fm-reconcile-stale.sh --clean --yes removes only stale state records"
}

test_dry_run_reports_stale_and_writes_nothing
test_clean_without_yes_refuses_and_writes_nothing
test_clean_refuses_unlanded_work
test_clean_refuses_live_endpoint
test_clean_respects_fleet_freeze
test_clean_yes_removes_only_state_and_tasktmp
