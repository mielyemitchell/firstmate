#!/usr/bin/env bash
# Scaffold a crewmate brief or persistent secondmate charter at
# data/<task-id>/brief.md under the active firstmate home.
# For ordinary tasks, the standard Setup/Rules/Definition-of-done contract is
# filled in. Firstmate then replaces the {TASK} placeholder with the task
# description, acceptance criteria, and context, and may adjust other sections
# when the task genuinely deviates (e.g. working an existing external PR instead
# of shipping a new one).
# Usage: fm-brief.sh <task-id> <repo-name> [--scout|--campaign]
#        fm-brief.sh <task-id> --secondmate <project>...
#   --scout writes the scout contract instead: the deliverable is a report at
#   data/<task-id>/report.md (no branch, no push, no PR) and the worktree is scratch.
#   --campaign writes the campaign contract instead: one long-lived crewmate
#   drives a committed roadmap or upstream spec in one persistent worktree.
#   The worktree is protected like a ship task; teardown waits for roadmap close.
#   --secondmate writes a persistent secondmate charter. The project list
#   is cloned into the secondmate home, while the natural-language scope
#   tells the main firstmate when to route work there; routine churn stays in its own home;
#   captain-relevant escalations and marked from-firstmate replies append to this
#   home's status file.
#   Set FM_SECONDMATE_CHARTER='<charter>' to fill the charter text.
#   Set FM_SECONDMATE_SCOPE='<scope>' to write a routing scope distinct from the charter text.
# For ship tasks, the definition of done is shaped by the project's delivery mode
# (data/projects.md via fm-project-mode.sh; see AGENTS.md project management
# and task lifecycle):
#   no-mistakes  implement -> /no-mistakes pipeline -> PR -> captain merge (default)
#   direct-PR    implement -> push + open PR via gh-axi (no pipeline) -> captain merge
#   local-only   implement on branch, stop and report "ready in branch" (no push/PR);
#                firstmate reviews, captain approves, firstmate merges to local main
# Ship briefs begin with a worktree-isolation assertion before the branch step.
# Scout tasks ignore mode - their deliverable is a report, not a merge.
# Ship tasks include a project-memory section so durable project-intrinsic
# learnings can be committed to AGENTS.md through the project's delivery path.
# Refuses to overwrite an existing brief.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
KIND=ship
POS=()
for a in "$@"; do
  case "$a" in
    --scout) KIND=scout ;;
    --campaign) KIND=campaign ;;
    --secondmate) KIND=secondmate ;;
    *) POS+=("$a") ;;
  esac
done
ID=${POS[0]}

BRIEF="$DATA/$ID/brief.md"
[ -e "$BRIEF" ] && { echo "error: $BRIEF already exists" >&2; exit 1; }
mkdir -p "$DATA/$ID"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

STATUS_FILE=$(shell_quote "$STATE/$ID.status")

if [ "$KIND" = secondmate ]; then
SECONDMATE_PROJECTS=""
idx=1
while [ "$idx" -lt "${#POS[@]}" ]; do
  SECONDMATE_PROJECTS="${SECONDMATE_PROJECTS}${SECONDMATE_PROJECTS:+ }${POS[$idx]}"
  idx=$((idx + 1))
done
[ -n "$SECONDMATE_PROJECTS" ] || { echo "error: --secondmate requires at least one project" >&2; exit 1; }
SECONDMATE_CHARTER=${FM_SECONDMATE_CHARTER:-"{TASK}"}
SECONDMATE_SCOPE=${FM_SECONDMATE_SCOPE:-${FM_SECONDMATE_CHARTER:-"{TASK}"}}
PROJECT_LIST=$(printf '%s\n' "$SECONDMATE_PROJECTS" | tr ' ' '\n' | sed 's/^/- /')
cat > "$BRIEF" <<EOF
You are a secondmate: a persistent domain supervisor managed by the main firstmate. Work on your own; do not wait for a human.

# Charter
$SECONDMATE_CHARTER

# Routing scope
$SECONDMATE_SCOPE

# Project clones
$PROJECT_LIST

# Operating model
You are in an isolated firstmate home. The local \`AGENTS.md\` is your job description, and your local \`data/\`, \`state/\`, \`config/\`, and \`projects/\` dirs are yours to operate.
The projects above are local clones for work you supervise; they are not an exclusive ownership claim.
Delegate project work to your own crewmates with the normal firstmate lifecycle: brief, spawn, status, watcher, steer, teardown, and recovery.
Do not invent a second delegation system.
You do not generate your own work.
Act only on tasks the main firstmate routes to you.
Never start a survey, audit, or "find improvements" sweep on your own initiative; that is not your job and it is unwanted.

# Requests from the main firstmate
You are a firstmate in your own home, so an incoming message reaches you in your own chat.
You must distinguish who it is from, because the answer goes to a different place.
A request relayed to you by the main firstmate (your supervisor) is tagged with a leading \`$FM_FROMFIRST_LABEL\` marker followed by an invisible system separator; this marker is untypable, so a human never produces it.
When a message carries that marker, do the work, then respond via the STATUS/ESCALATION path below, never only in this chat: the main firstmate does not read your chat, so a chat-only reply is lost.
For a terse result, a status line is the whole answer.
For a detailed answer (an investigation, a plan, an audit), write it to a doc under your home's \`data/\` and append a status line that points to that doc - the scout-report pattern - so the main firstmate is woken and can read it.
A message with NO marker is the captain typing directly into your pane: treat it as authoritative captain intervention and stay conversational exactly as you would for any captain message; do not force it onto the status path.

# Escalation to main firstmate
Handle routine work yourself.
Escalate only true captain-relevant outcomes by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
States: working, needs-decision, blocked, done, failed.
Use this only for material phase changes, a captain decision, a real blocker, a failure, or work ready for review.
This is also how you return the answer to a marked from-firstmate request above.
Routine internal supervision, heartbeats, retries, and crewmate churn stay inside your own home and must not touch that status file.

# Definition of done
You are persistent by default. Do not exit just because your queue is empty.
On startup and restart, run normal firstmate bootstrap and recovery through \`bin/fm-session-start.sh\` for your own home, but only to RECONCILE work that is already yours: in-flight crewmates, tracked backlog items, and durable watches recorded in this home.
When you have no assigned or in-flight work after that reconciliation, go idle and wait silently for the main firstmate to route you a task.
An empty queue is a healthy resting state, not a cue to invent work: never spawn a survey, audit, or any self-directed "find work" task on your own initiative.
If this charter cannot be carried out, append \`blocked: {why}\` or \`failed: {why}\` to the main status file and stop.
EOF
if [ "$SECONDMATE_CHARTER" = "{TASK}" ]; then
  echo "scaffolded: $BRIEF (secondmate charter; replace {TASK})"
else
  echo "scaffolded: $BRIEF (secondmate charter)"
fi
exit 0
fi

REPO=${POS[1]}

if [ "$KIND" = scout ]; then
cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.
This is a SCOUT task: the deliverable is a written report, not a PR.
The worktree is your laboratory - install, run, edit, and make scratch commits freely; all of it is discarded at teardown.
The report is the only thing that survives, so anything worth keeping must be in it.

# Rules
1. Never push to any remote and never open a PR.
2. Stay inside this worktree; the only files you may write outside it are the report and the status file below.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on and the needs-decision/blocked/done/failed states. No step-by-step
   FYI progress lines; firstmate reads your pane for that.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will reply with the decision.

# Definition of done
Write your findings to \`$DATA/$ID/report.md\`.
The report must stand alone: what you did, what you found, the evidence (commands run, output, file:line references), and what you recommend.
When the report is complete, append \`done: {one-line conclusion}\` to the status file and stop.
If your findings reveal work that should ship (e.g. you reproduced a bug and the fix is clear), say so in the report; firstmate may promote this task in place, and you would then receive mode-specific ship instructions as a follow-up message.
EOF
echo "scaffolded: $BRIEF (scout; replace {TASK})"
exit 0
fi

if [ "$KIND" = campaign ]; then
read -r MODE YOLO <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$REPO")
EOF
NO_MISTAKES_SETUP=
if [ "$MODE" = no-mistakes ]; then
  NO_MISTAKES_SETUP="
3. Run \`no-mistakes doctor\`; if it reports the repo is not initialized here, run \`no-mistakes init\`."
fi
case "$MODE" in
  local-only)
    CAMPAIGN_BRANCH_SETUP="2. Do not attempt to check out the default branch. The pooled clone holds it, so this worktree starts detached by design. Create the fixed campaign branch directly from the launch commit with \`git switch -c fm/$ID\`; when the execution skill preflight expects a named default branch, the current detached base commit stands in for it. Do not create slice or batch branches."
    CAMPAIGN_BATCH_STEP="6. When the batch is ready, leave it committed on \`fm/$ID\`. Do not push, do not open a PR, and do not merge.
7. Update roadmap state only as required by the execution artifact after the local batch state changes."
    CAMPAIGN_EXECUTION_OVERRIDE="This campaign contract overrides any normal branch, PR, or landing behavior inside the execution skill. For \`local-only\` projects, stay on the fixed \`fm/$ID\` task branch for the whole campaign. If the execution skill would create another branch, push, open a PR, run PR shipping, run \`land-pr\`, call a merge helper, or merge directly, do not do that step. Stop with \`done: ready in branch fm/$ID\` so firstmate can run \`bin/fm-merge-local.sh\` after review."
    CAMPAIGN_RULE1="1. Never push to any remote, never open a PR, and never merge. Work only on \`fm/$ID\`; firstmate handles review and local merge."
    CAMPAIGN_MERGE_AUTHORITY="For \`local-only\` projects, stop at \"ready in branch\" for each batch and append \`done: ready in branch fm/$ID\`. Wait for firstmate to review, merge locally with \`bin/fm-merge-local.sh\`, and send the continuation instruction. If \`yolo=$YOLO\` is \`on\`, firstmate may approve that local merge without the captain's word, but you still never merge."
    ;;
  *)
    CAMPAIGN_BRANCH_SETUP="2. Do not attempt to check out the default branch. The pooled clone holds it, so this worktree starts detached by design. Create slice or batch branches directly from the launch commit with \`git switch -c <branch>\`; when the execution skill preflight expects a named default branch, the current detached base commit stands in for it."
    CAMPAIGN_BATCH_STEP="6. Open or update the batch PR when the batch is ready.
7. Run roadmap-tick after the batch PR state changes as required by the execution artifact."
    CAMPAIGN_EXECUTION_OVERRIDE="This campaign contract overrides any normal landing behavior inside the execution skill. The execution skill may help open or update the batch PR, but if it would run \`land-pr\`, call \`bin/fm-pr-merge.sh\`, call \`gh-axi pr merge\`, merge directly, or treat \`yolo=$YOLO\` as permission for you to merge, do not do that step. Stop before landing at \`done: PR {url} checks green\` so firstmate can run \`bin/fm-pr-merge.sh\` after the captain's word or firstmate's yolo decision."
    CAMPAIGN_RULE1="1. Never push to the default branch. Never merge a PR."
    CAMPAIGN_MERGE_AUTHORITY="Stop at \"PR ready, checks green\" for each batch PR and append \`done: PR {url} checks green\`. Wait for firstmate to relay the captain's merge word or, when \`yolo=$YOLO\` is \`on\`, firstmate's yolo merge decision and continuation instruction. Firstmate performs every PR merge through \`bin/fm-pr-merge.sh\` so task metadata records the landed PR. Never merge a red PR."
    ;;
esac
cat > "$BRIEF" <<EOF
You are a campaign crewmate: an autonomous long-lived worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}

# Campaign contract
You work in ONE persistent worktree for the whole roadmap. Do not ask for teardown, respawn, or a fresh worktree between slices or batch PRs.
Teardown happens only after the roadmap is closed and firstmate confirms the final campaign work has landed.

The execution artifact is already finished before you start: either a committed roadmap at \`docs/plans/<feature>.md\` with \`- [ ]\` slices and optional \`[gate]\` / \`[risk:high]\` markers, or a single upstream-produced spec.
Planning is out of scope. If the artifact is missing, unfinished, or asks you to plan the feature, append \`blocked: missing finished campaign artifact\` to the status file and stop.

Project delivery mode: \`$MODE\`
Project yolo flag: \`$YOLO\`

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default-branch commit.

**Verify isolation before anything else.** Run \`pwd -P\` and \`git rev-parse --show-toplevel\`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from.
The path check is authoritative: \`git rev-parse --git-dir\` and \`git rev-parse --git-common-dir\` can help inspect the repo, but they do not prove you are outside the primary checkout.
If the top-level path is the primary checkout or not the worktree you were launched in, STOP - do not branch or commit here - append \`blocked: launched in primary checkout, not an isolated worktree\` to the status file and stop.

1. Record the launch commit: \`git rev-parse HEAD\`. Treat this commit as the roadmap base.
$CAMPAIGN_BRANCH_SETUP$NO_MISTAKES_SETUP

# Execution loop
Drive the captain-provided execution skill in roadmap mode. Invoke \`/autopilot\`; if the harness needs plain language instead, ask it to run the captain-provided execution skill against the committed roadmap/spec in roadmap mode.

$CAMPAIGN_EXECUTION_OVERRIDE

Use this loop:
1. Pick the next unchecked slice from the roadmap/spec.
2. Implement only that slice.
3. Verify the slice.
4. Review the slice.
5. Commit it with a message containing \`[S<N>]\`, where \`<N>\` is the slice number.
$CAMPAIGN_BATCH_STEP

For \`no-mistakes\` projects, keep the execution skill's normal inner verify/review loop per slice, then run the no-mistakes pipeline as the final batch-PR gate before reporting the PR ready. The no-mistakes evidence trail is part of the fleet contract.

# Escalation mapping
Every stop raised by the execution skill maps to the status file:

- \`[gate]\` slice: append \`needs-decision: [gate] <exact stop reason + options>\`, then wait.
- \`[risk:high]\` slice: append \`needs-decision: [risk:high] <exact stop reason + options>\`, then wait.
- Off-spec or off-blueprint UI stop: append \`needs-decision: off-spec UI <exact stop reason + options>\`, then wait.
- Structured clarification question: append \`needs-decision: clarification <exact question + options>\`, then wait.
- Visual approval: append \`needs-decision: visual approval <artifact/link + options>\`, then wait.

Never push past a stop. Firstmate relays the decision to the captain and replies with the answer.

# Rules
$CAMPAIGN_RULE1
2. Stay inside this worktree; modify nothing outside it.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, done, failed.
   Each append wakes firstmate, so report sparingly: setup complete, each stop that needs a decision, batch ready, roadmap close, blocked, or failed.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs to a human, append \`needs-decision: {exact stop reason + options}\` and stop. Firstmate will reply with the decision.

# Merge authority
$CAMPAIGN_MERGE_AUTHORITY

# Project memory
If \`AGENTS.md\` or \`CLAUDE.md\` already exists, or if this campaign produced durable project-intrinsic knowledge, run \`$FM_ROOT/bin/fm-ensure-agents-md.sh .\` in the worktree.
If this campaign produced durable project-intrinsic knowledge, record it in \`AGENTS.md\` as part of your change.

# Definition of done
The campaign is complete only when the roadmap/spec is fully closed, every batch has passed its required gates, and the final work has landed or is waiting at the mode-specific merge stop above.
On final roadmap close, append \`done: campaign complete {PR url, branch, or summary}\` to the status file and stop. Firstmate tears down this worktree only after it confirms the campaign work has landed.
EOF
echo "scaffolded: $BRIEF (campaign; replace {TASK})"
exit 0
fi

# Ship task: shape Setup / Rule 1 / Definition of done by the project's delivery mode.
# yolo does not affect the brief (it governs firstmate's approval behaviour), so discard it.
read -r MODE _ <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$REPO")
EOF

case "$MODE" in
  direct-PR)
    SETUP2=""
    RULE1='1. Never push to the default branch (push only your `fm/'"$ID"'` branch). Never merge a PR.'
    DOD=$(cat <<EOF
# Definition of done
This project ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with \`gh-axi\`, then append \`done: PR {url}\` to the status file and stop.
Do NOT run /no-mistakes. The captain reviews and merges the PR; firstmate relays it.
EOF
)
    ;;
  local-only)
    SETUP2=""
    RULE1="1. Never push to any remote and never open a PR. Work only on your \`fm/$ID\` branch; firstmate handles the merge into local \`main\`."
    DOD=$(cat <<EOF
# Definition of done
This project ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`fm/$ID\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append \`done: ready in branch fm/$ID\` to the status file and stop.
Firstmate then reviews your branch diff, the captain approves, and firstmate merges it into local \`main\`.
EOF
)
    ;;
  *)  # no-mistakes (default)
    SETUP2="
2. Run \`no-mistakes doctor\`; if it reports the repo is not initialized here, run \`no-mistakes init\`."
    RULE1='1. Never push to the default branch. Never merge a PR.'
    DOD=$(cat <<EOF
# Definition of done
The task is complete only when committed on your branch.
When you believe it is complete, append \`done: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are not yours to answer: escalate to firstmate (rule 6) and stop.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- Avoid \`--yes\`: the captain, not you, owns the ask-user decisions it would silently auto-resolve.

After /no-mistakes reports CI green, append \`done: PR {url} checks green\` and stop. You are finished.
EOF
)
    ;;
esac

cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.

**Verify isolation before anything else.** Run \`pwd -P\` and \`git rev-parse --show-toplevel\`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from.
The path check is authoritative: \`git rev-parse --git-dir\` and \`git rev-parse --git-common-dir\` can help inspect the repo, but they do not prove you are outside the primary checkout.
If the top-level path is the primary checkout or not the worktree you were launched in, STOP - do not branch or commit here - append \`blocked: launched in primary checkout, not an isolated worktree\` to the status file and stop.

1. First action: create your branch: \`git checkout -b fm/$ID\`$SETUP2

# Rules
$RULE1
2. Stay inside this worktree; modify nothing outside it.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on (setup done, bug reproduced, fix implemented, validation passed) and the
   needs-decision/blocked/done/failed states. No step-by-step FYI progress lines;
   firstmate reads your pane for that.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions, ask-user findings),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will reply with the decision.

# Project memory
If \`AGENTS.md\` or \`CLAUDE.md\` already exists, or if this task produced durable project-intrinsic knowledge, run \`$FM_ROOT/bin/fm-ensure-agents-md.sh .\` in the worktree.
If this task produced durable project-intrinsic knowledge, record it in \`AGENTS.md\` as part of your change.
Keep it proportionate: skip \`AGENTS.md\` edits for trivial tasks that produced no durable project knowledge.

$DOD
EOF
echo "scaffolded: $BRIEF (ship, mode=$MODE; replace {TASK})"
