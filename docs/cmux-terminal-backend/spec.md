# cmux terminal backend spec

## What

Add a terminal backend boundary to firstmate so workers can run in visible cmux panes while keeping the existing tmux implementation as the default fallback.

First slice: cmux mode can spawn one visible ship/scout worker in an isolated treehouse worktree, send it the brief, read its screen, detect terminal outcomes, and clean it up safely. Secondmates stay on the existing tmux path until a later slice.

## Context

firstmate currently assumes tmux in its core lifecycle:

- `bin/fm-spawn.sh` creates tmux windows, runs `treehouse get`, launches the harness, and records `window=<session:window>`.
- `bin/fm-send.sh` sends prompts with tmux key injection.
- `bin/fm-peek.sh` reads panes with tmux capture.
- `bin/fm-watch.sh` detects stale/busy workers from tmux pane text.
- `bin/fm-teardown.sh` kills tmux windows and returns treehouse worktrees.

Manual smoke tests on 2026-06-29 proved cmux has the needed primitives:

- visible worker panes can launch `pi` directly;
- `cmux send` can steer an idle worker;
- `cmux read-screen` can read worker output;
- `cmux send-key ctrl+c` can interrupt a long command;
- parallel cmux workers can use separate treehouse worktrees and commit safely;
- cleanup can return treehouse worktrees, close surfaces, and preserve committed branches.

## Requirements

- Preserve existing tmux behavior unless cmux mode is explicitly selected or safely auto-detected.
- Add a backend boundary instead of scattering cmux conditionals through every script.
- Support at least these backend operations:
  - spawn surface/window in a project/worktree path;
  - send literal text and submit it reliably (`cmux send` requires a trailing `\n` / `\r` to press Enter);
  - send special keys, especially `ctrl+c` / Escape / Enter where supported;
  - read recent screen text;
  - detect whether the worker is busy from footer text;
  - close the worker surface/window;
  - store a durable target handle in `state/<id>.meta`.
- For cmux mode, record enough metadata to recover after firstmate restarts: `terminal_backend=cmux`, `workspace=...`, `surface=...`, `pane=...`, `worktree=...`.
- All scripts that read meta must tolerate cmux tasks without `window=`; today some paths assume `window=` exists under `set -e`, so target resolution must move behind the backend boundary before cmux meta is written.
- For tmux mode, continue to record existing `window=<session:window>` and keep old scripts compatible.
- Use `treehouse get --lease --lease-holder <id>` for cmux worker acquisition so spawn can get the worktree path without an interactive subshell.
- Return cmux worktrees with `treehouse return --force <worktree>` only after the same landed/dirty safety checks already used by teardown.
- If cmux CLI/socket is unavailable, fail clearly or fall back to tmux depending on config.

## Design

### Config

Add a local config knob:

```text
config/terminal-backend
```

Allowed values:

- `tmux` — current behavior.
- `cmux` — visible cmux workers.
- absent / `auto` — use cmux only when `CMUX_WORKSPACE_ID` and `cmux ping` are available; otherwise tmux.

Add optional local layout config:

```text
config/cmux-layout
```

Allowed values:

- `splits` — a visible right-split off firstmate per worker (vertical strips).
- `tabs` — one crew pane (first worker splits) with worker tabs.
- `hybrid` — split up to `FM_CMUX_SPLIT_THRESHOLD`, then tab overflow (the pre-grid `auto` behaviour, kept under its own name).
- absent / `auto` — Mielye default: firstmate pinned left, workers tile a grid to its right, overflowing to a new window when the grid is full (see Layout policy).

### Backend library

Add a new backend abstraction, likely:

```text
bin/fm-terminal-lib.sh
bin/fm-terminal-tmux.sh
bin/fm-terminal-cmux.sh
```

The public functions should be small and shell-friendly:

```sh
fm_terminal_backend_resolve
fm_terminal_spawn <id> <cwd> <title> <launch-command>
fm_terminal_send <id-or-target> <text>
fm_terminal_send_key <id-or-target> <key>
fm_terminal_read <id-or-target> <lines>
fm_terminal_busy <id-or-target>
fm_terminal_close <id-or-target>
```

Use shell-safe function names; avoid pseudo-subcommands in function names unless implemented as one dispatcher function with an explicit subcommand argument.

Existing scripts call the generic functions. Backend files own tmux/cmux command details.

Target compatibility rules:

- Bare `fm-<id>` resolves through `state/<id>.meta` and chooses the backend recorded there.
- Explicit `session:window` remains a tmux escape hatch for existing operators/tests.
- cmux targeting uses `workspace + surface`; pane is recorded for layout/recovery, but `surface` is the normal send/read/close target.

### cmux spawn shape

For cmux worker spawn:

1. Resolve current workspace from `CMUX_WORKSPACE_ID` or `cmux identify --json`.
2. Lease worktree:
   ```sh
   WT=$(cd "$PROJECT" && treehouse get --lease --lease-holder "$ID")
   ```
3. Create worker pane/surface based on layout policy, capturing the returned `workspace`, `pane`, and `surface` refs.
4. Start the harness in `WT` with the generated launch command by sending a single setup command to the new surface, for example `cd <WT> && export GOTMPDIR=... && <launch>\n`. cmux split/surface commands do not take `cwd` / `command` flags the way `new-workspace` does.
5. Record meta only after the worktree and surface exist and launch setup has been sent:
   ```text
   terminal_backend=cmux
   workspace=workspace:N
   pane=pane:N
   surface=surface:N
   worktree=/...
   project=/...
   harness=pi|claude|codex|...
   kind=ship|scout
   mode=...
   yolo=...
   tasktmp=/tmp/fm-<id>
   ```

### Layout policy

Mielye default (`auto`): firstmate's own pane stays pinned on the **left** and is
never sliced into a strip. Workers tile into a **grid** to its right — a 2-row
grid filled column-major (a 2×2 for the default capacity of 4). When the grid is
full the next worker opens a **new cmux window** and the grid fills again there.

Concrete tiling for `auto` (capacity `FM_CMUX_GRID_CAPACITY`, default 4; rows
`FM_CMUX_GRID_ROWS`, default 2):

- Worker 1: `cmux new-split right` off firstmate's caller surface → top-right cell.
- Worker 2: `cmux new-split down` off worker 1's surface → bottom of column 1.
- Worker 3: `cmux new-split right` off worker 1's surface → top of column 2.
- Worker 4: `cmux new-split down` off worker 3's surface → bottom of column 2.
- Worker 5 (grid full): `cmux new-window`, a `cmux new-workspace` in it, and a
  `cmux new-pane` terminal surface — then the grid fills again in that window.

Later workers anchor (split) off a **prior worker's** surface with an alternating
direction, so firstmate is only ever the anchor for worker 1. Anchors are
resolved from the recorded worker `surface`/`workspace` values in `state/*.meta`,
ordered by cmux's monotonically-increasing surface ref (a later worker gets a
higher number), so ordering is stable across meta appends and across windows.
Every command that accepts `--focus` passes `--focus false`; `cmux new-window` is
bare (no `--focus` flag) and is the one command that can take focus.

Tunables (local, env): `FM_CMUX_GRID_CAPACITY` sets how many workers fill one grid
(one window) before overflow; `FM_CMUX_GRID_ROWS` sets the grid height;
`FM_CMUX_SPLIT_THRESHOLD` still governs `hybrid`.

Implementation history:

- first cmux slice created one right-side worker pane only;
- second slice added split counting + hybrid tab overflow;
- this slice replaced the `auto` default with the grid + new-window policy above
  (`hybrid` keeps the old split-then-tab behaviour under its own name).

### Outcome detection

Do not depend only on visual text long-term. Preserve status-file signaling where harness hooks already exist.

For cmux screen-reading, detect public markers as fallback:

- `done:` / `ready in branch` / `checks green`
- `needs-decision:` / `NEEDS_DECISION:`
- `blocked:`
- `failed:` / `FAILED:`

Busy detection can reuse the current busy footer patterns:

- Claude/Codex: `esc to interrupt`
- Pi: `Working...`
- Grok: `Ctrl+c:cancel`

### Cleanup

cmux teardown must preserve the current safety invariant:

- never close/return a worker with uncommitted work unless explicitly forced;
- never discard committed work not merged/pushed/landed;
- close cmux surface only after worktree safety checks pass;
- if close-surface fails, leave metadata and report the surface handle.

## Decisions

- Use backend abstraction, not a one-off cmux fork.
- Keep tmux fallback.
- Use `treehouse get --lease` for cmux instead of interactive `treehouse get`.
- Default UX (`auto`) is firstmate pinned left with workers in a grid to its right, overflowing to a new window when the grid is full; `hybrid` retains the earlier split-to-threshold-then-tab behaviour.
- First implementation slice should not attempt every firstmate feature at once.
- X mode is additive over the terminal backend, not a per-backend fork (slice 4). The X-path scripts (`bin/fm-x-*.sh`) and the `fmx-respond` skill are terminal-independent: they only read/write `state/<id>.meta` by line and talk to the relay, never reading `window=` or calling tmux. An X mention that spawns real work rides the same cmux-aware lifecycle as any task — `fm-spawn.sh` (slices 1–2), `fm-watch.sh` (slice 1), and `fm-crew-state.sh` (slice 1) — so the audit found no residual tmux/`window=` assumption to fix.

## Invariants

- A worker must never edit the primary project checkout directly.
- A worker must always run in a distinct treehouse worktree for project work.
- Teardown must refuse dirty or unlanded work unless forced by explicit user approval.
- Existing tmux behavior and tests must keep passing.
- Meta files must contain enough target information for recovery.
- cmux focus should not be stolen unless the user explicitly asks; use `--focus false` where supported.

## Error behavior

- If `config/terminal-backend=cmux` but `cmux ping` fails, spawn exits with a clear error and does not create a task meta file.
- If cmux pane creation succeeds but harness launch fails, keep the pane open and report the surface handle for inspection.
- If treehouse lease succeeds but cmux spawn fails before meta is written, return the lease or clearly report the leased worktree path.
- If cmux surface creation succeeds but later setup fails, preserve enough temporary state in the error output for manual cleanup (`workspace`, `surface`, `worktree`).
- If screen read fails, report `unknown` rather than guessing worker state.
- If cleanup cannot close the cmux surface, preserve metadata and report manual cleanup instructions.

## Acceptance criteria

- Given `config/terminal-backend=tmux`, when a sandbox worker is spawned, then existing tmux window behavior still works and current tests pass.
- Given `config/terminal-backend=cmux` inside cmux, when a sandbox worker is spawned, then a visible cmux surface opens and runs the harness in a leased treehouse worktree.
- Given a cmux worker is idle, when firstmate sends a follow-up instruction, then the worker receives it and acts on it.
- Given a cmux worker has output, when firstmate peeks/reads it, then recent screen text is returned without using tmux.
- Given a cmux worker prints `needs-decision:` or `FAILED:`, when supervision reads the surface, then the state is classified as needing attention or failed.
- Given a cmux worker runs a long foreground command, when firstmate sends interrupt, then the command stops and the worker surface remains usable.
- Given a cmux worker has uncommitted changes, when teardown runs without force, then cleanup is refused and the surface stays open.
- Given a cmux worker has committed work that is merged/landed, when teardown runs, then treehouse returns the worktree and cmux closes the surface.

Later-slice layout acceptance:

- Given `auto` and an empty-to-full grid, when workers 1–4 spawn, then they tile a 2×2 grid to firstmate's right (right/down/right/down, anchored off firstmate then prior workers), with firstmate never sliced into a strip.
- Given `auto` and a full grid (`FM_CMUX_GRID_CAPACITY` workers), when another worker spawns, then it opens a new cmux window and is placed there instead of piling more splits/tabs into the existing window.
- Given `config/cmux-layout=splits|tabs|hybrid`, when workers spawn, then each forces its named shape and none steal focus.

Slice 4 X-mode-under-cmux acceptance:

- Given `config/terminal-backend=cmux`, when an actionable X mention spawns a task, then it spawns a cmux worker (no `window=`; `terminal_backend=cmux` + `surface`) through the normal lifecycle, with no X-specific spawn path.
- Given a cmux task, when `bin/fm-x-link.sh` links it to its originating mention, then `x_request=`/`x_request_ts=` are recorded and every cmux meta field is preserved, and no `window=` line is introduced.
- Given a cmux X-linked task reaches a terminal state, when the completion wake fires (via `fm-crew-state.sh`, slice 1), then `bin/fm-x-followup.sh --check` reports the due `request_id` and the single follow-up posts through `bin/fm-x-reply.sh --followup`; a link past the 24h window is pruned silently.

## Verification loop

Cheapest proof for first slice:

1. Run existing firstmate shell tests.
2. Run a tmux sandbox spawn to prove fallback was not broken.
3. Run cmux sandbox smoke:
   - spawn worker visibly;
   - send prompt;
   - read screen;
   - detect done/failure/needs-decision marker;
   - interrupt long command;
   - teardown safely.
4. Verify branch/commit preservation from the primary sandbox repo after cleanup.
5. Layout policy: under `auto`, spawn workers in sequence and confirm workers 1–4 tile a 2×2 grid to firstmate's right (right/down/right/down, anchored off firstmate then prior workers) and worker 5 opens a new cmux window; confirm `config/cmux-layout=splits|tabs|hybrid` force the expected shape and none steal focus. Automated coverage lives in `tests/fm-terminal-cmux.test.sh` (grid arithmetic, grid command shapes, new-window overflow, cross-window anchoring, focus).
6. Secondmate cmux (slice 3): with `config/terminal-backend=cmux`, route/spawn a secondmate and confirm it opens a visible cmux surface in its persistent firstmate home (no treehouse worktree lease), placed by the same layout policy without stealing focus; its meta records `terminal_backend=cmux` + `surface`/`workspace`/`pane` + `home`/`projects` and no `worktree=`/`window=`; the pre-launch home fast-forward and config inheritance still run; and the watcher leaves the idle secondmate surface alone (idle = healthy).
7. X mode under cmux (slice 4): automated coverage lives in `tests/fm-x-cmux.test.sh` — the link records into a cmux meta (no `window=`), `fm-x-followup.sh --check` reports/prunes the due `request_id` for a cmux-linked task, the dry-run follow-up loop clears the link, and the X path never shells out to tmux for a cmux task (tmux tripwire). Manual live-cmux checklist (needs a live relay + cmux app): with `FMX_PAIRING_TOKEN` in `.env` and `config/terminal-backend=cmux`, post an actionable mention to `@myfirstmate`, then confirm the poll wakes firstmate, `fmx-respond` spawns a **visible cmux worker** for the work, `bin/fm-x-link.sh` links it, and when that cmux worker finishes the single completion follow-up posts back to the mention (verify via `state/x-outbox/` under `FMX_DRY_RUN` first, then live).

## Testing strategy

- Unit-test backend target parsing and config resolution with shell tests.
- Stub `cmux` in tests for spawn/send/read/close command formation.
- Keep existing tmux tests untouched and passing.
- Add one manual cmux integration checklist because full cmux UI behavior needs a live cmux app/socket.

## Out of scope for first slice

- Replacing every watcher path in one PR.
- Full secondmate cmux support; secondmate spawn remains tmux-only in the first slice even when `config/terminal-backend=cmux`. (Landed later in slice 3: secondmates launch in cmux surfaces in their persistent home — see verification step 6.)
- X mode / public reply integration. (Audited in slice 4: X mode is additive and already works under cmux via the slices-1–3 cmux-aware lifecycle — no core change needed; see verification step 7 and `tests/fm-x-cmux.test.sh`.)
- Automatic PR creation or no-mistakes changes.
- Polished status UI, badges, or notifications beyond basic surface naming/flash.
- Removing tmux.

## Handoff

Next: `single-task-build` for the first vertical slice: backend config + cmux spawn/send/read/cleanup for one sandbox worker, preserving tmux fallback.
