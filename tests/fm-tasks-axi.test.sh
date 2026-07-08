#!/usr/bin/env bash
# Behavior tests for the firstmate tasks-axi wrapper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-tasks-axi)
WRAP="$ROOT/bin/fm-tasks-axi.sh"

make_tasks_home() {
  local home=$1 path=${2:-data/backlog.md}
  mkdir -p "$home/data" "$home/config"
  printf '[backend.markdown]\npath = "%s"\n' "$path" > "$home/.tasks.toml"
  printf '## Queued\n' > "$home/data/backlog.md"
}

make_tasks_axi_fakebin() {
  local dir=$1 log=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\n' 'tasks-axi 0.1.1'
  exit 0
fi
printf 'cwd=%s\n' "\$(pwd -P)" >> '$log'
printf 'args=%s\n' "\$*" >> '$log'
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  printf '%s\n' "$fakebin"
}

test_wrapper_runs_from_fm_home() {
  local home home_real log fakebin out status
  home="$TMP_ROOT/home"
  log="$TMP_ROOT/tasks.log"
  make_tasks_home "$home"
  home_real=$(cd "$home" && pwd -P)
  fakebin=$(make_tasks_axi_fakebin "$TMP_ROOT/fake" "$log")

  set +e
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$WRAP" "done" task-a --pr https://example.invalid/pr/1 2>&1)
  status=$?
  set -e

  expect_code 0 "$status" "wrapper should run fake tasks-axi successfully"
  [ -z "$out" ] || fail "wrapper should not print on successful pass-through: $out"
  assert_grep "cwd=$home_real" "$log" "wrapper did not cd to FM_HOME before tasks-axi"
  assert_grep "args=done task-a --pr https://example.invalid/pr/1" "$log" "wrapper did not pass through args"
  pass "fm-tasks-axi runs tasks-axi from FM_HOME"
}

test_wrapper_refuses_config_outside_home() {
  local home outside fakebin out status
  home="$TMP_ROOT/bad-home"
  outside="$TMP_ROOT/outside/backlog.md"
  mkdir -p "$(dirname "$outside")"
  make_tasks_home "$home" "$outside"
  fakebin=$(make_tasks_axi_fakebin "$TMP_ROOT/fake-bad" "$TMP_ROOT/bad.log")

  set +e
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$WRAP" "done" task-a --note local 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "wrapper should refuse backlog paths outside FM_HOME"
  assert_contains "$out" "resolves outside FM_HOME" "wrapper did not explain unsafe tasks-axi config"
  pass "fm-tasks-axi refuses configs that point outside FM_HOME"
}

test_wrapper_runs_from_fm_home
test_wrapper_refuses_config_outside_home

echo "# all fm-tasks-axi tests passed"
