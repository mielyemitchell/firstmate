#!/usr/bin/env bash
# tests/fm-secondmate-cmux.test.sh - Phase B slice 3: a secondmate launches in a
# cmux surface (bin/fm-spawn.sh spawn_cmux_and_exit) when the terminal backend is
# cmux, mirroring the tmux secondmate semantics exactly - only the terminal changes.
#
# What this locks down (must not regress):
#   - a cmux-mode secondmate spawn does NOT lease a treehouse worktree (it runs in
#     its persistent firstmate home), creates a cmux surface via the layout policy,
#     launches with a `cd <home>` + FM_HOME=<home> line and the persistent charter,
#     and records kind=secondmate + terminal_backend=cmux + surface/workspace/pane
#     + home/projects meta with NO worktree=/window=;
#   - the backend-independent secondmate invariants still run on the cmux path:
#     inheritable-config propagation into the home's config/, and NO per-worktree
#     turn-end hook (no pi-ext.ts) - both mirror the tmux secondmate path;
#   - the tmux secondmate path is unchanged: with no cmux backend a secondmate still
#     records window= and never touches cmux;
#   - the always-on watcher skips a cmux secondmate's stale-pane wake (idle = healthy):
#     it enumerates the cmux secondmate as fm-<id> but never reads its screen.
#
# The tmux secondmate lifecycle (seed/send/handoff/recovery/teardown) is owned by
# fm-secondmate-lifecycle-e2e.test.sh; the cmux crewmate layout policy by
# fm-terminal-cmux.test.sh; the watcher cmux crewmate path by fm-watch-cmux.test.sh.
set -u

# shellcheck source=tests/secondmate-helpers.sh
# secondmate-helpers.sh brings seed/spawn fixtures (make_fake_tmux, the fake
# treehouse, scaffold_secondmate_charter, wait_live) and lib.sh. wake-helpers.sh is
# deliberately NOT sourced: it exports FM_ROOT_OVERRIDE at source time, which would
# repoint fm-spawn/fm-home-seed away from the real repo. The one watcher-path helper
# needed (a pane hash) is tiny and defined locally.
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-cmux)

# Same pane-hash the watcher's hash_pane computes (md5 of the screen text).
hash_text() {
  if command -v md5 >/dev/null 2>&1; then printf '%s' "$1" | md5 -q; else printf '%s' "$1" | md5sum | cut -d' ' -f1; fi
}

HOME_DIR="$TMP_ROOT/main-home"
SUB="$TMP_ROOT/triage-home"
SUB_ABS=
FAKEBIN=
TMUX_LOG="$TMP_ROOT/tmux.log"     # fake tmux + fake treehouse activity
CMUX_LOG="$TMP_ROOT/cmux.log"     # fake cmux activity

# A fake cmux that logs every call and serves the spawn primitives (identify,
# split/pane/surface creation, pane lookup) plus read-screen for the watcher path.
install_cmux_stub() {  # <fakebin>
  cat > "$1/cmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${CMUX_FAKE_LOG:-/dev/null}"
case "${1:-}" in
  ping) exit 0 ;;
  identify) printf '{"caller":{"workspace_ref":"workspace:1","surface_ref":"surface:5"}}\n'; exit 0 ;;
  new-split|new-pane|new-surface) printf 'created surface:7 workspace:1\n'; exit 0 ;;
  list-panes) printf 'pane:3\n'; exit 0 ;;
  list-pane-surfaces) printf 'surface:7\n'; exit 0 ;;
  read-screen) printf '%s\n' "${CMUX_FAKE_SCREEN:-idle prompt}"; exit 0 ;;
  send|send-key|rename-tab|close-surface) exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$1/cmux"
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# --- shared world: a seeded triage secondmate home --------------------------
setup_world() {
  mkdir -p "$HOME_DIR/projects" "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config"
  fm_git_init_commit "$HOME_DIR/projects/alpha"
  fm_git_add_origin "$HOME_DIR/projects/alpha" "$TMP_ROOT/remotes/alpha.git"
  cat > "$HOME_DIR/data/projects.md" <<EOF
- alpha [direct-PR] - alpha project (added 2026-06-30)
EOF
  FAKEBIN=$(make_fake_tmux "$TMP_ROOT/fake")
  install_cmux_stub "$FAKEBIN"

  FM_SECONDMATE_SCOPE='triage from brief' \
    scaffold_secondmate_charter "$HOME_DIR" triage 'triage charter' alpha \
    || fail "secondmate charter scaffold failed"

  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-home-seed.sh" triage "$SUB" alpha >/dev/null \
    || fail "seed failed"
  SUB_ABS=$(cd "$SUB" && pwd -P)
}

# --- cmux secondmate spawn --------------------------------------------------
test_cmux_secondmate_launches_in_surface() {
  : > "$TMUX_LOG"; : > "$CMUX_LOG"
  # Force the cmux backend, and put an inheritable value in the parent config so we
  # can prove config inheritance still runs on the cmux secondmate path.
  printf 'cmux\n' > "$HOME_DIR/config/terminal-backend"
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  rm -f "$HOME_DIR/state/triage.meta" "$HOME_DIR/state/triage.pi-ext.ts"

  local out
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" CMUX_FAKE_LOG="$CMUX_LOG" \
    "$ROOT/bin/fm-spawn.sh" triage "$SUB" codex --secondmate 2>/dev/null) \
    || fail "cmux secondmate spawn failed"

  # Success line reports a cmux secondmate landing in its home (not a worktree).
  assert_contains "$out" 'kind=secondmate' "spawn success line did not report kind=secondmate"
  assert_contains "$out" 'terminal=cmux' "spawn success line did not report the cmux terminal"
  assert_contains "$out" "home=$SUB_ABS" "spawn success line did not report the home"

  # No treehouse lease: a secondmate runs in its persistent home, never a worktree.
  assert_no_grep 'treehouse get' "$TMUX_LOG" "cmux secondmate spawn leased a treehouse worktree"
  assert_no_grep 'treehouse ' "$TMUX_LOG" "cmux secondmate spawn invoked treehouse at all"

  # A cmux surface was created via the layout policy (first worker -> visible split),
  # never stealing focus.
  assert_grep 'new-split right --workspace workspace:1 --surface surface:5 --focus false' "$CMUX_LOG" \
    "cmux secondmate did not create a surface through the layout policy"

  # The launch cd's to the HOME and runs the harness with the persistent charter and
  # cleared operational overrides pointed at the home (mirrors the tmux path).
  assert_grep "cd '$SUB_ABS'" "$CMUX_LOG" "cmux secondmate launch did not cd to the home"
  assert_grep "FM_HOME='$SUB_ABS'" "$CMUX_LOG" "cmux secondmate launch did not set FM_HOME to the home"
  assert_grep 'FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE=' "$CMUX_LOG" \
    "cmux secondmate launch did not clear operational overrides"
  assert_grep "$SUB_ABS/data/charter.md" "$CMUX_LOG" "cmux secondmate launch did not use the persistent charter"

  # Meta: cmux target fields + secondmate fields, and crucially NO worktree=/window=.
  local meta="$HOME_DIR/state/triage.meta"
  assert_grep 'terminal_backend=cmux' "$meta" "meta did not record terminal_backend=cmux"
  assert_grep 'kind=secondmate' "$meta" "meta did not record kind=secondmate"
  assert_grep 'mode=secondmate' "$meta" "meta did not record mode=secondmate"
  assert_grep 'yolo=off' "$meta" "meta did not record yolo=off"
  assert_grep 'workspace=workspace:1' "$meta" "meta did not record the cmux workspace"
  assert_grep 'surface=surface:7' "$meta" "meta did not record the cmux surface"
  assert_grep 'pane=pane:3' "$meta" "meta did not record the cmux pane"
  assert_grep "home=$SUB_ABS" "$meta" "meta did not record the home"
  assert_grep 'projects=alpha' "$meta" "meta did not record the project list"
  assert_no_grep 'worktree=' "$meta" "cmux secondmate meta wrongly recorded a worktree"
  assert_no_grep 'window=' "$meta" "cmux secondmate meta wrongly recorded a tmux window"

  # Backend-independent secondmate invariants still run on the cmux path:
  # inheritable-config propagation into the home's config/ (proof the pre-guard
  # secondmate block, which also does the home fast-forward, executed)...
  assert_grep 'codex' "$SUB/config/crew-harness" "cmux secondmate spawn did not propagate inheritable config into the home"
  # ...and NO per-worktree turn-end hook (mirror tmux: secondmates skip it).
  assert_absent "$HOME_DIR/state/triage.pi-ext.ts" "cmux secondmate wrongly wrote a turn-end hook"

  pass "cmux secondmate: launches in its home surface (no lease), records secondmate+cmux meta, keeps config inheritance and skips the turn-end hook"
}

# --- tmux secondmate path is unchanged --------------------------------------
test_tmux_secondmate_unchanged() {
  : > "$TMUX_LOG"; : > "$CMUX_LOG"
  # Force the tmux backend explicitly (a stubbed cmux answering ping plus a set
  # CMUX_WORKSPACE_ID would otherwise auto-resolve to cmux): the secondmate must
  # take the existing tmux path, recording a window= and never touching cmux.
  printf 'tmux\n' > "$HOME_DIR/config/terminal-backend"
  rm -f "$HOME_DIR/state/triage.meta"

  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/pane.txt" CMUX_FAKE_LOG="$CMUX_LOG" \
    "$ROOT/bin/fm-spawn.sh" triage "$SUB" codex --secondmate >/dev/null 2>&1 \
    || fail "tmux secondmate spawn failed"

  local meta="$HOME_DIR/state/triage.meta"
  assert_grep 'window=firstmate:fm-triage' "$meta" "tmux secondmate did not record its window"
  assert_grep 'kind=secondmate' "$meta" "tmux secondmate meta did not record kind=secondmate"
  assert_grep "home=$SUB_ABS" "$meta" "tmux secondmate meta did not record the home"
  assert_no_grep 'terminal_backend=cmux' "$meta" "tmux secondmate wrongly recorded the cmux backend"
  [ ! -s "$CMUX_LOG" ] || fail "the tmux secondmate path invoked cmux (should stay tmux-only): $(cat "$CMUX_LOG")"
  pass "tmux secondmate path is unchanged (window= meta, cmux never invoked)"
}

# --- watcher skips a cmux secondmate's stale-pane wake ----------------------
test_watcher_skips_cmux_secondmate() {
  local dir state fakebin out cmux_log key pid
  dir="$TMP_ROOT/cmux-sm-skip"; state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; cmux_log="$dir/cmux.log"
  mkdir -p "$state" "$fakebin" "$dir/home"
  install_cmux_stub "$fakebin"
  fm_fake_exit0 "$fakebin" tmux
  # A cmux secondmate meta: terminal_backend=cmux + workspace/surface/pane, kind=
  # secondmate, home=, and crucially NO window=. The watcher enumerates it as
  # fm-<id> and must skip it as a supervised secondmate (idle = healthy).
  fm_write_meta "$state/triagesm.meta" \
    'terminal_backend=cmux' \
    'workspace=workspace:1' \
    'surface=surface:2' \
    'pane=pane:3' \
    'harness=codex' \
    'kind=secondmate' \
    'mode=secondmate' \
    "home=$dir/home"
  # Prime a stable (stale) pane hash so a NON-secondmate worker here would surface.
  local screen='idle prompt, awaiting routed work'
  key=$(printf '%s' "fm-triagesm" | tr ':/.' '___')
  printf '%s' "$(hash_text "$screen")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  PATH="$fakebin:$PATH" CMUX_FAKE_LOG="$cmux_log" CMUX_FAKE_SCREEN="$screen" \
    FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then reap "$pid"; fail "watcher exited for an idle cmux secondmate (should skip as healthy): $(cat "$out")"; fi
  [ ! -s "$out" ] || { reap "$pid"; fail "idle cmux secondmate printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "idle cmux secondmate enqueued a durable wake record"; }
  # The skip happens BEFORE the screen read, so the secondmate triggers ZERO cmux
  # calls: an empty (or absent) cmux log proves its surface was never read.
  [ ! -s "$cmux_log" ] || { reap "$pid"; fail "watcher invoked cmux for a secondmate (should skip it entirely): $(cat "$cmux_log")"; }
  reap "$pid"
  pass "watcher skips a cmux secondmate's stale-pane wake (idle = healthy, screen never read)"
}

# --- a cmux secondmate counts like any other cmux worker for layout -----------
# Phase B slice 3 makes a cmux secondmate a first-class worker in the layout count,
# so it participates in split/tab placement decisions (its own and later workers').
test_cmux_secondmate_counts_as_worker() {
  local dir state n
  dir="$TMP_ROOT/count"; state="$dir/state"; mkdir -p "$state"
  fm_write_meta "$state/sm.meta" 'terminal_backend=cmux' 'pane=pane:1' 'surface=surface:1' 'kind=secondmate'
  fm_write_meta "$state/ship.meta" 'terminal_backend=cmux' 'pane=pane:2' 'surface=surface:2' 'kind=ship'
  # Both a cmux secondmate and a cmux crewmate count; excluding one by id leaves 1.
  n=$(STATE="$state" bash -c '. "$1"; fm_terminal_cmux_worker_count "$2"' _ "$ROOT/bin/fm-terminal-lib.sh" newcomer)
  [ "$n" = 2 ] || fail "cmux worker count did not include the secondmate (expected 2, got $n)"
  n=$(STATE="$state" bash -c '. "$1"; fm_terminal_cmux_worker_count "$2"' _ "$ROOT/bin/fm-terminal-lib.sh" ship)
  [ "$n" = 1 ] || fail "cmux secondmate was not counted as a worker (expected 1, got $n)"
  pass "a cmux secondmate counts like any other cmux worker in the layout policy"
}

setup_world
test_cmux_secondmate_launches_in_surface
test_tmux_secondmate_unchanged
test_watcher_skips_cmux_secondmate
test_cmux_secondmate_counts_as_worker
