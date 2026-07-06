#!/usr/bin/env bash
# tests/fm-fleet-map.test.sh - read-only fleet map behavior.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FLEET_MAP="$ROOT/bin/fm-fleet-map.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-map-tests)

new_world() {
  local name=$1 home state fixture
  home="$TMP_ROOT/$name/home"
  state="$home/state"
  fixture="$TMP_ROOT/$name/herdr.json"
  mkdir -p "$state" "$(dirname "$fixture")"
  printf '%s|%s|%s\n' "$home" "$state" "$fixture"
}

test_maps_tracked_state_to_visible_herdr_by_cwd() {
  local rec home state fixture out
  rec=$(new_world mapped)
  IFS='|' read -r home state fixture <<EOF
$rec
EOF

  fm_write_meta "$state/task-a.meta" \
    "backend=herdr" \
    "window=default:w1:p1" \
    "worktree=$TMP_ROOT/work-a" \
    "kind=ship"
  fm_write_meta "$state/task-b.meta" \
    "backend=herdr" \
    "window=default:w2:p2" \
    "worktree=$TMP_ROOT/work-b" \
    "kind=scout"
  fm_write_meta "$state/task-c.meta" \
    "backend=herdr" \
    "window=default:w9:p9" \
    "worktree=$TMP_ROOT/work-c" \
    "kind=ship"

  cat > "$fixture" <<JSON
{
  "result": {
    "agents": [
      {"name": "firstmate", "agent_status": "idle", "terminal_id": "term-main", "pane_id": "w1:p0", "cwd": "$home"},
      {"name": "worker-a", "agent_status": "working", "terminal_id": "term-a", "pane_id": "w1:p1", "cwd": "$TMP_ROOT/work-a-creation-cwd"},
      {"name": "worker-c-wrong-pane", "agent_status": "idle", "terminal_id": "term-c", "pane_id": "w9:p8", "cwd": "$TMP_ROOT/work-c"},
      {"name": "raw-worker", "agent_status": "idle", "terminal_id": "term-raw", "pane_id": "w4:p4", "cwd": "$TMP_ROOT/raw"}
    ]
  }
}
JSON

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_FLEET_MAP_HERDR_JSON="$fixture" "$FLEET_MAP")

  assert_contains "$out" $'task-a\tship\therdr\tdefault:w1:p1' "tracked task-a did not print"
  assert_contains "$out" $'task-a\tship\therdr\tdefault:w1:p1\t'"$TMP_ROOT/work-a"$'\ttarget-match:worker-a' "task-a did not match visible Herdr agent by exact target"
  assert_contains "$out" $'worker-a\tworking\tterm-a\tdefault:w1:p1\t'"$TMP_ROOT/work-a-creation-cwd"$'\ttask-a' "Herdr agent ownership did not use exact target before cwd"
  assert_not_contains "$out" "operator-untracked-herdr name=worker-a" "target-matched Herdr agent was wrongly labelled operator-untracked"
  assert_contains "$out" "stale-tracked id=task-b" "missing visible Herdr agent for task-b was not warned"
  assert_contains "$out" $'task-c\tship\therdr\tdefault:w9:p9\t'"$TMP_ROOT/work-c"$'\tcwd-only:worker-c-wrong-pane' "task-c did not distinguish cwd-only match from exact target match"
  assert_contains "$out" "cwd-only-match id=task-c" "cwd-only target mismatch was not warned"
  assert_contains "$out" "operator-untracked-herdr name=firstmate" "untracked current firstmate chat was not surfaced"
  assert_contains "$out" "operator-untracked-herdr name=raw-worker" "raw Herdr worker was not warned"

  pass "fm-fleet-map.sh maps tracked state to visible Herdr agents and warns on drift"
}

test_herdr_unavailable_still_prints_tracked_state() {
  local rec home state fixture out
  rec=$(new_world unavailable)
  IFS='|' read -r home state fixture <<EOF
$rec
EOF

  fm_write_meta "$state/task-c.meta" \
    "backend=herdr" \
    "window=default:w3:p3" \
    "worktree=$TMP_ROOT/work-c" \
    "kind=ship"

  out=$(PATH=/usr/bin:/bin FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$FLEET_MAP")

  assert_contains "$out" $'task-c\tship\therdr\tdefault:w3:p3' "tracked state should print even without Herdr"
  assert_contains "$out" "HERDR AGENTS" "Herdr section missing"
  assert_contains "$out" "unavailable" "Herdr unavailable state missing"
  assert_contains "$out" "herdr-unavailable" "unavailable warning missing"
  assert_not_contains "$out" "stale-tracked id=task-c" "stale warnings require live Herdr inventory"

  pass "fm-fleet-map.sh keeps tracked-state diagnostics useful when Herdr is unavailable"
}

test_maps_tracked_state_to_visible_herdr_by_cwd
test_herdr_unavailable_still_prints_tracked_state
