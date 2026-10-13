# Code review: learnings and optimization plan

Status: **notes and plan**. Only the bash stdin fix, the diagnostic script,
and keeping the findings of failed runs (3.1) are implemented. Everything else
under "Optimizations" is a proposal.

This document records what we learned while debugging `review_changes` failing
when the root agent invoked it. It also lists what the two traced runs tell us
about making `Tackle.Review` faster, cheaper, more reliable, and more visible.

## 1. The incident

**Symptom.** Reviews started by the root agent (`review_changes`) reported units
as "not reviewed: timed out" and took the full 5-minute inactivity window. The
same review from `tackle review` or `/review` seemed to work.

**Root cause.** The bash tool started commands with the executor port's stdin
left open as a pipe that nothing writes to. A command that reads stdin waits
forever, and the bash tool has no default timeout. Examples are `rg PATTERN`
without a path, `grep PATTERN`, `cat`, and `read`. The delegated run then emits
no events, and `Tackle.Runtime.Request` settles it as `:timeout` after the
scope's `run_timeout` (5 minutes).

The first traced run shows it directly. Detector `nix/packages/jail-git.sh#2` ran

```
git status --short; cat nix/packages/jail-git.sh; cat nix/packages/exec-jail.nix; rg 'jail_git|jail-git' -n
```

received the `git` and `cat` output, and was silent for 300 s until the idle
timeout fired.

**Why it looked agent-specific.** It is not. Every path starts bash the same
way, so the hang is probabilistic: it happens only when a model writes such a
command without a `timeout`. Three things made it look specific to the agent:

- **Batching.** Units are batched, so one hung run failed every unit in its
  batch. An earlier agent run reported 6 failed units from about two hung runs.
- **No progress.** `review_changes` reports no progress, so the agent's review
  looked frozen for minutes.
- **Different concurrency.** The tool path runs more detectors at once (see
  2.1), which makes a hang somewhat more likely per review.

**Fix (implemented).** `Tackle.Tools.Bash` runs every command as
`exec </dev/null; <command>`. The redirect shares the command's first line, so
Bash's line numbers in error messages still match. Both are covered by tests in
`packages/tackle/test/tackle/tools/bash_test.exs`, run against the local and
jailed executors. The stdin test fails without the fix.

**Verified.** With the fix, the same review (`HEAD~1..HEAD`, agent mode) ran all
9 delegated runs to `ok`, with no unit failures.

## 2. Measurements

Both runs: agent mode, `openai-codex/gpt-6.1-sol` at thinking `high`, streaming
on, not jailed, profile `quiet`. The change is 7 files, +358/−35, mostly Nix,
shell, and docs. Costs and tokens are summed from the stages' `step_end` usage.

| | Run 1 (no fix) | Run 2 (fix) |
|---|---|---|
| Wall time | 375 s | 403 s |
| Delegated runs | 8 (5 detectors, 3 verifiers) | 9 (5 detectors, 4 verifiers) |
| Failed or timed-out runs | 1 (hung `rg`) | 0 |
| Model steps | 57 | 60 |
| Max steps in one run | 14 | 16 |
| Tool calls | 50 (41 bash, 2 read) | 51 (39 bash, 3 read) |
| bash calls using `ketch`/`curl` (network) | 17 | 7 |
| bash calls reading `/nix/store` | 7 | 10 |
| Failed tool calls | 11 | 9 |
| Input / cached / output tokens | 233k / 1.12M / 15k | 205k / 1.09M / 18k |
| Cost | ≈ $0.73 | ≈ $0.70 |
| Blocking findings | 2 | 3 |

Durations of the run-2 detectors:

| Detector | Duration |
|---|---|
| change-level overview | 345 s |
| `jail-git.sh#2` | 268 s |
| 5-unit doc/Nix batch | 170 s |
| `jail-git.sh#1` | 67 s |
| `jailed-tackle-cli.nix#1` | 47 s |

Verifiers took 25–30 s each.

## 3. Learnings and optimizations

### 3.1 Robustness

- **Timeouts should say what the run was doing.** "timed out" alone cost us a
  debugging session. When a delegated review run times out, the error should
  carry its last non-auxiliary event, for example "timed out after bash `rg …`"
  or "timed out waiting for the model (step 4)". It should appear in the tool
  result, in `Result.summary.failed_units`, and in the TUI.
- **Keep what failed runs reported (implemented).** Detectors report
  findings incrementally (`report_findings` with `done: false`), and a run
  that fails, times out, crashes, or is cancelled on its own keeps what it
  reported: the delegation mirrors the run's finished messages from its
  events, so even a timed-out run's transcript is available. Such units are
  listed in `Result.summary.incomplete_units`; a run cancelled alone no
  longer cancels the whole review.
- **Retry failed units once, unbatched.** One hung or crashed run in a batch
  fails all its units. A failed batch should be split and its units retried
  once, individually, before they are reported as not reviewed. Notes should
  say "a batch of 5 units timed out" rather than list five independent
  failures.
- **Give the review stages a default bash timeout.** The stdin fix removes one
  class of hang. A slow network call or a `find /` can still stall a detector
  for 5 minutes. Options:
  - an executor- or profile-level default timeout for the stage profiles'
    bash, such as 60 s;
  - a dedicated read-only search tool (see 3.2).
- **Silent reasoning counts as inactivity.** Every run showed `deltas=0`, even
  with streaming on. Run 2's longest silent model step was about 82 s. A
  heavier reasoning step at a higher thinking level could reach the 300 s idle
  timeout without anything being stuck.
  - Investigate whether provider streaming or reasoning events reach the
    request helper.
  - If they can't, have the loop emit a periodic non-auxiliary heartbeat while
    a model request is in flight.
- **Unify concurrency.** `Tackle.Review` defaults to the handle's
  `max_children_per_agent` (4) for a `Handle` requester and 2 for an
  `AgentRef`. So the agent tool and `tackle review` behave differently for no
  stated reason. Pick one policy and document it, ideally configurable per
  host.

### 3.2 Detector focus, time, and cost

- **Detectors leave the change.** In run 1, 17 of 41 bash calls used the
  network (`ketch search`, `ketch scrape`, `curl` of git's source on GitHub).
  Detectors also read `/nix/store` in both runs. That costs time, tokens, and
  failed tool calls (`ketch extract` doesn't exist, and searches timed out),
  and the network is a leak risk for private code.
  - **Prompt:** forbid network access and anything outside the repository.
  - **Enforcement:** run the stage profiles in the jail without network, or
    replace bash with narrow read-only tools: a search tool with a required
    path and a timeout, plus `read`.
- **Fewer guessed paths.** Several failed calls came from guessed paths, such
  as `rg … tests` (no such directory) or `executor*` globs. Giving the
  detector a short repository map would avoid these. That map is the list of
  changed files plus top-level directories.
- **Redundant reading.** Detectors open with `git status; cat <whole file>`,
  although the unit already contains the hunks with their surrounding
  function. Tell them the unit's context is complete. Also include the
  file's path list and line count, so they read only what is missing.
- **The change-level unit is the critical path.** It ran 345 s over about 12
  steps and finished last, so it sets the review's wall time.
  - Give it a smaller step budget than file units.
  - Or give it a cheaper or lower-thinking model through the stage's
    `:models`/`:thinking` options.
- **Docs-only units are expensive.** The batch of five Markdown/Nix units took
  170–350 s and reported nothing blocking. Consider profile-dependent handling:
  `quiet` could skip or lighten pure documentation, through rules or the
  existing `:exclude` globs.
- **Cost is reasonable and cache-friendly.** About $0.70 per review of this
  size, with about 1.1M cached tokens against about 220k uncached. The shared
  prompt cache key per stage works. Report the cost in the tool result too;
  `ReviewOutput.cost_summary` already exists for the TUI and CLI.

### 3.3 Quality and stability

- **High run-to-run variance.** The two runs reviewed identical input and
  produced **disjoint** blocking findings:
  - run 1: linked-worktree settings checks; indirect Git configuration and
    hooks;
  - run 2: host Git credentials exposed; blocking on replacement FIFOs;
    clobbering concurrent config writes.

  All five are plausible, so a single review has low recall. The pipeline
  already supports `:samples` (detector runs per batch, `tackle review
  --samples`), but `review_changes` and `/review` don't expose it.
  - Measure recall versus cost for `samples` 1–3.
  - Expose it, or tie it to the profile (`assertive` → 2).
- **Build an evaluation set.** A handful of commits with known, seeded defects
  in this repository, reviewed N times each, would turn "feels better" into
  recall and precision numbers. The repository's `Tackle.Review.History`
  already stores outcomes (useful, not useful, dismissed, fixed) that can serve
  as precision labels over time.
- **Range reviews read the working tree.** For `HEAD~1..HEAD` the detectors ran
  `git status` and saw unrelated local modifications, and they read files from
  the working tree. When the working tree differs from the reviewed head,
  detectors and verifiers may reason about code that isn't in the change. For
  range and staged reviews, they should read the reviewed revision. Options:
  - tell them to use `git show <head>:path`;
  - give them a read-only checkout of the head.

### 3.4 Visibility (TUI and tool)

- **`review_changes` reports no progress.** The agent's tool card shows nothing
  for 5–7 minutes. Emit the `Tackle.Review` events as progress events from the
  tool, as `run_workflow` does with `:workflow_progress`. Render them inline:
  stages, units, candidates, and verdicts, using the existing
  `Tackle.CLI.TUI.ReviewProgress` projection.
- **Agent reviews aren't actionable in the TUI.** Findings from the agent's
  review only exist as tool-result text. Keep the result so the `/review`
  overlay can open it, with useful / dismiss / fix actions.
- **What to show while running.** The trace shows what a person wants to see:
  - which unit each run reviews;
  - its current step and last tool call (for example "bash: rg … nix");
  - time since its last activity;
  - running cost.

  That is a per-unit activity line plus a stall marker, and a cost/elapsed
  header.
- **Overlay redesign.** These are the earlier proposals, still open:
  - a three-pane result view (files → findings → detail with an annotated
    diff);
  - filters and severity badges;
  - a summary tab;
  - re-review markers (new / still present / fixed).

### 3.5 Diagnostics

`apps/tackle_cli/bench/review_repro.exs` reproduces a review with the
interactive shell's composition and traces every delegated run, without
modifying the harness:

```sh
cd apps/tackle_cli
mix run --no-start bench/review_repro.exs --range HEAD~1..HEAD 2>&1 | tee review_repro.log
```

It offers three modes:

- `agent`: the root calls the tool mid-turn;
- `tool`: the tool is called directly with the root's context;
- `cli`: `Tackle.Review.run/2` from the root ref, as `tackle review` does.

`--model`, `--thinking`, and `--no-stream` match other setups.

What it prints:

- every run's events;
- admission refusals;
- scope status every 15 s;
- for a run silent longer than `--stall` seconds, a stack dump of its
  processes. The dump covers the session, turn task, and tool tasks, down to
  the OS process behind a bash port.

**Limitations:**

- Call tracing applies to the whole VM.
- The root session is not durable.
- It has not been run jailed.
- The `tool` and `agent` modes are only checked against live models, not a
  fake adapter.
- Its findings belong in this document, not in regression tests. Each
  confirmed cause gets a focused test, like the bash stdin test.

## 4. Suggested order

1. Last activity in timeout errors, and a retry of failed batches as single
   units (3.1). Both are small, and they make every later failure
   self-explaining.
2. Progress events from `review_changes` and an inline TUI card (3.4). This
   makes the agent path usable.
3. Detector containment: no network, repository only, a bash timeout or a
   search tool (3.2). Expect lower time, cost, and failure rate.
4. Reading the reviewed revision for range and staged reviews (3.3).
5. An evaluation set, then tuning `samples`, the change-level unit's budget,
   and docs handling against it (3.2, 3.3).
6. The overlay redesign (3.4).
