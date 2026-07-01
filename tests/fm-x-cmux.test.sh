#!/usr/bin/env bash
# Prove the X-mention -> (cmux) spawn -> supervise -> completion-follow-up loop
# works for a cmux task, i.e. that X mode is additive under the cmux terminal
# backend (Phase B slice 4, audit-and-prove).
#
# Why no core change was needed: the X path is terminal-INDEPENDENT. fm-x-link.sh,
# fm-x-followup.sh, and fm-x-reply.sh only read/write state/<id>.meta by line and
# talk to the relay - none of them reads window=, calls tmux, or assumes a tmux
# window. The terminal-touching hops the loop rides (spawn via fm-spawn.sh,
# supervision via fm-watch.sh, current-state detection via fm-crew-state.sh) were
# already made cmux-aware in slices 1-3 and are pinned by their own suites
# (fm-terminal-cmux, fm-watch-cmux, fm-crew-state). This suite pins the remaining
# X-specific claim: the link/follow-up records into and reads from a cmux meta
# (terminal_backend=cmux, surface=, and NO window=) exactly as it does for a tmux
# meta, and never shells out to tmux to do it.
#
# A cmux meta is written exactly as fm-spawn.sh's spawn_cmux_and_exit writes it:
# terminal_backend/workspace/pane/surface plus worktree/project, and crucially NO
# window= line. The network is never touched here - link and --check are offline,
# and the follow-up loop is exercised with FMX_DRY_RUN, which records the would-be
# post to state/x-outbox instead of calling the relay. jq stays the real tool.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
# The follow-up dry-run path (fm-x-reply.sh) uses the real jq; make it resolvable
# regardless of where it is installed, prepended so it wins over BASE_PATH but
# after the tmux tripwire below.
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-x-cmux-tests)

# A cmux ship-task meta exactly as fm-spawn.sh writes for a cmux worker:
# terminal_backend=cmux, workspace/pane/surface, worktree/project, and NO window=.
write_cmux_meta() { # <home> <id>
  local home=$1 id=$2
  mkdir -p "$home/state"
  fm_write_meta "$home/state/$id.meta" \
    'terminal_backend=cmux' \
    'workspace=workspace:1' \
    'pane=pane:3' \
    'surface=surface:2' \
    'harness=pi' \
    'kind=ship' \
    'mode=no-mistakes' \
    'yolo=off' \
    'tasktmp=/tmp/t' \
    'model=default' \
    'effort=default' \
    "worktree=$home/wt" \
    "project=$home/proj"
}

# A tmux tripwire: a stub that records any invocation and fails loudly. Placed
# FIRST on PATH so it shadows any real tmux; if the X path ever shells out to tmux
# for a cmux-meta task, the sentinel appears and the exit code is non-zero. This
# turns "no tmux dependency" from a code-read into an executable assertion.
make_tmux_tripwire() { # <dir> -> fakebin
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
: > "${FM_TMUX_TRIPPED:?FM_TMUX_TRIPPED unset}"
echo "tmux was invoked for a cmux task: $*" >&2
exit 3
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# ---------------------------------------------------------------------------

test_link_records_into_cmux_meta_without_window() {
  local home meta out rc
  home="$TMP_ROOT/link-cmux"; mkdir -p "$home"
  write_cmux_meta "$home" cmux-ship-a
  meta="$home/state/cmux-ship-a.meta"
  out=$(FM_HOME="$home" FMX_NOW_OVERRIDE=1700000000 \
    "$ROOT/bin/fm-x-link.sh" cmux-ship-a req-cmux-a); rc=$?
  expect_code 0 "$rc" "link into cmux meta exit"
  assert_grep "x_request=req-cmux-a" "$meta" "link must record the request_id in a cmux meta"
  assert_grep "x_request_ts=1700000000" "$meta" "link must record the timestamp in a cmux meta"
  # The cmux-specific fields must survive verbatim - this is the crux: the link
  # rewrite drops only x_request/x_request_ts and preserves every other line.
  assert_grep "terminal_backend=cmux" "$meta" "link must preserve terminal_backend=cmux"
  assert_grep "surface=surface:2" "$meta" "link must preserve the cmux surface"
  assert_grep "workspace=workspace:1" "$meta" "link must preserve the cmux workspace"
  assert_grep "pane=pane:3" "$meta" "link must preserve the cmux pane"
  assert_grep "kind=ship" "$meta" "link must preserve kind"
  # And it must NOT invent a tmux window= line for a cmux task.
  assert_no_grep "window=" "$meta" "link must not introduce a window= line into a cmux meta"
  # Re-linking replaces rather than duplicating, exactly as for a tmux meta.
  FM_HOME="$home" FMX_NOW_OVERRIDE=1700009999 \
    "$ROOT/bin/fm-x-link.sh" cmux-ship-a req-cmux-b >/dev/null
  [ "$(grep -c '^x_request=' "$meta")" = "1" ] || fail "re-link must not duplicate x_request in a cmux meta"
  assert_grep "x_request=req-cmux-b" "$meta" "re-link must replace the request_id"
  assert_no_grep "window=" "$meta" "re-link must still not introduce a window= line"
  pass "fm-x-link records the X link into a cmux meta and never adds a window="
}

test_followup_check_for_cmux_linked_task() {
  local home meta out rc
  home="$TMP_ROOT/fu-check-cmux"; mkdir -p "$home"
  write_cmux_meta "$home" cmux-ship-b
  meta="$home/state/cmux-ship-b.meta"
  FM_HOME="$home" FMX_NOW_OVERRIDE=1700000000 \
    "$ROOT/bin/fm-x-link.sh" cmux-ship-b req-cmux-c >/dev/null
  # Within the 24h window -> exit 0, prints the request_id for the cmux task.
  out=$(FM_HOME="$home" FMX_NOW_OVERRIDE=1700003600 \
    "$ROOT/bin/fm-x-followup.sh" --check cmux-ship-b); rc=$?
  expect_code 0 "$rc" "cmux followup --check within-window exit"
  [ "$out" = "req-cmux-c" ] || fail "check on a cmux-linked task must print the request_id (got: $out)"
  # A cmux task that never came from an X mention -> exit 1, silent (not linked).
  write_cmux_meta "$home" cmux-ship-plain
  out=$(FM_HOME="$home" "$ROOT/bin/fm-x-followup.sh" --check cmux-ship-plain 2>/dev/null); rc=$?
  expect_code 1 "$rc" "cmux followup --check not-linked exit"
  [ -z "$out" ] || fail "check on a non-linked cmux task must be silent (got: $out)"
  # Past the 24h window -> exit 1, silent, and the link is pruned while the cmux
  # fields stay intact.
  out=$(FM_HOME="$home" FMX_NOW_OVERRIDE=$((1700000000 + 25*3600)) \
    "$ROOT/bin/fm-x-followup.sh" --check cmux-ship-b 2>/dev/null); rc=$?
  expect_code 1 "$rc" "cmux followup --check expired exit"
  [ -z "$out" ] || fail "check on an expired cmux link must be silent (got: $out)"
  assert_no_grep "x_request=" "$meta" "expired --check must prune the link from a cmux meta"
  assert_grep "terminal_backend=cmux" "$meta" "expired --check must preserve the cmux fields"
  assert_no_grep "window=" "$meta" "expired --check must not introduce a window= line"
  pass "fm-x-followup --check reports the due request_id for a cmux-linked task and prunes on expiry"
}

test_followup_dry_run_loop_for_cmux_meta() {
  local home meta out rc
  home="$TMP_ROOT/fu-loop-cmux"; mkdir -p "$home"
  write_cmux_meta "$home" cmux-ship-c
  meta="$home/state/cmux-ship-c.meta"
  FM_HOME="$home" FMX_NOW_OVERRIDE=1700000000 \
    "$ROOT/bin/fm-x-link.sh" cmux-ship-c req-cmux-d >/dev/null
  # The completion follow-up (dry-run) records the would-be post and clears the
  # link exactly as a live post would - the whole acknowledge -> act -> follow-up
  # loop for a cmux task, without a token or the relay.
  out=$(PATH="$BASE_PATH" FM_HOME="$home" FMX_DRY_RUN=1 FMX_NOW_OVERRIDE=1700003600 \
    "$ROOT/bin/fm-x-followup.sh" cmux-ship-c - <<<"Done, captain - shipped and green." 2>/dev/null); rc=$?
  expect_code 0 "$rc" "cmux followup dry-run post exit"
  [ "$out" = "req-cmux-d" ] || fail "cmux followup dry-run must echo the request_id (got: $out)"
  assert_present "$home/state/x-outbox/req-cmux-d.json" "cmux followup dry-run must record the would-be follow-up"
  [ "$(jq -r '.endpoint' "$home/state/x-outbox/req-cmux-d.json")" = "followup" ] \
    || fail "cmux followup dry-run must carry the followup endpoint marker"
  assert_no_grep "x_request=" "$meta" "a cmux followup post must clear the link"
  assert_grep "terminal_backend=cmux" "$meta" "clearing the link must preserve the cmux fields"
  assert_no_grep "window=" "$meta" "the follow-up loop must not introduce a window= line"
  pass "fm-x-followup runs the completion follow-up loop for a cmux-linked task (dry-run)"
}

test_x_path_never_shells_out_to_tmux_for_cmux_task() {
  local home meta fakebin tripped rc out
  home="$TMP_ROOT/no-tmux-cmux"; mkdir -p "$home"
  write_cmux_meta "$home" cmux-ship-d
  meta="$home/state/cmux-ship-d.meta"
  fakebin=$(make_tmux_tripwire "$home")
  tripped="$home/tmux-tripped"
  # tmux tripwire FIRST on PATH so it shadows any real tmux; jq/coreutils follow.
  # Run every X-path hop the loop uses for a cmux task: link, --check, and the
  # dry-run follow-up post. None may invoke tmux.
  out=$(PATH="$fakebin:$BASE_PATH" FM_TMUX_TRIPPED="$tripped" FM_HOME="$home" \
    FMX_NOW_OVERRIDE=1700000000 \
    "$ROOT/bin/fm-x-link.sh" cmux-ship-d req-cmux-e); rc=$?
  expect_code 0 "$rc" "link under tmux tripwire exit"
  assert_absent "$tripped" "fm-x-link must not shell out to tmux for a cmux task"
  out=$(PATH="$fakebin:$BASE_PATH" FM_TMUX_TRIPPED="$tripped" FM_HOME="$home" \
    FMX_NOW_OVERRIDE=1700003600 \
    "$ROOT/bin/fm-x-followup.sh" --check cmux-ship-d); rc=$?
  expect_code 0 "$rc" "check under tmux tripwire exit"
  [ "$out" = "req-cmux-e" ] || fail "check under tripwire must still print the request_id (got: $out)"
  assert_absent "$tripped" "fm-x-followup --check must not shell out to tmux for a cmux task"
  out=$(PATH="$fakebin:$BASE_PATH" FM_TMUX_TRIPPED="$tripped" FM_HOME="$home" \
    FMX_DRY_RUN=1 FMX_NOW_OVERRIDE=1700003600 \
    "$ROOT/bin/fm-x-followup.sh" cmux-ship-d - <<<"Shipped." 2>/dev/null); rc=$?
  expect_code 0 "$rc" "followup post under tmux tripwire exit"
  assert_absent "$tripped" "fm-x-followup post must not shell out to tmux for a cmux task"
  pass "the X path never invokes tmux for a cmux-meta task (terminal-independent)"
}

test_link_records_into_cmux_meta_without_window
test_followup_check_for_cmux_linked_task
test_followup_dry_run_loop_for_cmux_meta
test_x_path_never_shells_out_to_tmux_for_cmux_task
