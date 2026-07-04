#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issue
# #166): each ship-mode branch builds its Definition-of-done text with
# `VAR=$(cat <<EOF ... EOF)`. Bash's lexer tracks quote state through the
# heredoc body while it scans for the matching `)` of the command
# substitution, so a single unescaped apostrophe anywhere in that body breaks
# parsing of the *entire rest of the script* - `bash -n` fails, not just the
# generated brief. A plain `cat > file <<EOF ... EOF` (not wrapped in `$(...)`)
# is unaffected, so the secondmate charter block does not need this guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief)

# The script itself must always parse. This is the direct regression test for
# issue #166: a stray apostrophe in any of the three DOD heredoc bodies
# (no-mistakes/direct-PR/local-only) breaks `bash -n` on the whole file.
test_script_parses() {
  bash -n "$ROOT/bin/fm-brief.sh" 2>&1 || fail "bin/fm-brief.sh fails bash -n (heredoc/quote regression)"
  pass "fm-brief.sh: bash -n succeeds"
}

# Registry with one project per delivery mode, so each ship-mode DOD branch is
# exercised. A project absent from the registry defaults to no-mistakes.
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
- campaign-proj [direct-PR +yolo] - fixture for campaign mode+yolo wording (added 2026-07-01)
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_proj in "brief-nomistakes-a1:no-registry-proj" "brief-directpr-a2:direct-proj" "brief-localonly-a3:local-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id $proj should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "no-mistakes DOD lost its guidance-reference sentence"
  assert_no_grep "no-mistakes' own guidance" "$brief" \
    "no-mistakes DOD regressed to the apostrophe form that breaks bash -n"
  pass "fm-brief.sh: no-mistakes DOD wording avoids the apostrophe regression"
}

test_campaign_brief_contract() {
  local home id brief
  home="$TMP_ROOT/campaign-home"
  write_registry "$home"
  id="brief-campaign-c1"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" campaign-proj --campaign >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "campaign brief was not scaffolded"
  assert_grep "# Campaign contract" "$brief" "campaign brief missing Campaign contract section"
  assert_grep "ONE persistent worktree" "$brief" "campaign brief missing persistent worktree contract"
  assert_grep "docs/plans/<feature>.md" "$brief" "campaign brief missing committed roadmap path contract"
  assert_grep "Planning is out of scope" "$brief" "campaign brief must exclude planning"
  assert_grep "Project delivery mode: \`direct-PR\`" "$brief" "campaign brief did not include project delivery mode"
  assert_grep "Project yolo flag: \`on\`" "$brief" "campaign brief did not include project yolo flag"
  assert_grep "Treat this commit as the roadmap base" "$brief" "campaign brief missing detached-base adaptation"
  assert_grep "Do not attempt to check out the default branch" "$brief" "campaign brief missing no-default-checkout instruction"
  assert_grep "Invoke \`/autopilot\`" "$brief" "campaign brief missing execution-skill invocation"
  assert_grep "needs-decision: [gate]" "$brief" "campaign brief missing gate escalation mapping"
  assert_grep "needs-decision: [risk:high]" "$brief" "campaign brief missing high-risk escalation mapping"
  assert_grep "no-mistakes pipeline as the final batch-PR gate" "$brief" "campaign brief missing no-mistakes final gate"
  assert_grep "done: PR {url} checks green" "$brief" "campaign brief missing non-yolo merge stop report"
  assert_grep "Firstmate performs every PR merge through \`bin/fm-pr-merge.sh\`" "$brief" "campaign brief must reserve PR merge authority for firstmate"
  assert_grep "firstmate's yolo merge decision" "$brief" "campaign brief must route yolo merge decisions through firstmate"
  assert_no_grep "may merge through its own readiness gates" "$brief" "campaign brief delegated yolo merge authority to the crewmate"
  assert_grep "Teardown happens only after the roadmap is closed" "$brief" "campaign brief missing teardown timing"
  pass "fm-brief.sh: --campaign generates the roadmap-mode campaign contract"
}

test_campaign_local_only_brief_contract() {
  local home id brief
  home="$TMP_ROOT/campaign-local-home"
  write_registry "$home"
  id="brief-campaign-local-c2"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj --campaign >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "local-only campaign brief was not scaffolded"
  assert_grep "Project delivery mode: \`local-only\`" "$brief" "local-only campaign brief did not include project delivery mode"
  assert_grep "Do not push, do not open a PR, and do not merge" "$brief" "local-only campaign brief allowed PR or merge delivery"
  assert_grep "done: ready in branch {branch}" "$brief" "local-only campaign brief missing ready-in-branch stop"
  assert_grep "firstmate handles review and local merge" "$brief" "local-only campaign brief missing firstmate local merge ownership"
  assert_grep "bin/fm-merge-local.sh" "$brief" "local-only campaign brief missing local merge helper"
  assert_no_grep "Open or update the batch PR" "$brief" "local-only campaign brief still asks for a batch PR"
  pass "fm-brief.sh: local-only campaigns stop ready in branch"
}

test_script_parses
test_ship_modes_generate_clean_briefs
test_no_mistakes_dod_wording
test_campaign_brief_contract
test_campaign_local_only_brief_contract
