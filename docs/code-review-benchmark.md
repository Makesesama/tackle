# Code review: benchmark findings and the chosen defaults

Status: **measured and adopted.** This document records the benchmark runs of
2026-10-13 and 2026-10-14 that set the current defaults of `Tackle.Review`,
and explains why we chose them. Related documents:

- [`code-review-research.md`](code-review-research.md): the published
  evidence. Source IDs S1–S16 and finding numbers §1–§14 refer to it.
- [`code-review-plan.md`](code-review-plan.md): the original design.
- [`REVIEW_LEARNINGS.md`](REVIEW_LEARNINGS.md): what traced production
  reviews showed before this benchmark existed.
- [`apps/tackle_cli/bench/review_eval/README.md`](../apps/tackle_cli/bench/review_eval/README.md):
  how to run the benchmark.

## Summary

The detector and the verifier each run as a delegated agent per review unit
or batch of candidates, and they make up almost all of a review's cost. We
compared the previous defaults with cheaper configurations on 7 cases of
this repository with 18 seeded bugs.

**Decision.** The review stages now run with these settings:

| setting | before | now |
|---|---|---|
| System prompt of detector and verifier | assignment, `APPEND_SYSTEM.md`, `AGENTS.md`, skills | assignment and working directory (`instructions: false`) |
| Detector step limit | 40 | 6, and each run is told its budget of tool-call rounds |
| Verifier step limit | 25 | 6 |
| Thinking of the review stages | the session's level | the session's level; `low` recommended via `review.thinking` in `config.json` |

The measured configuration (6 and 6 steps, budget instruction, `low`
thinking) found **35 of 36** seeded bugs over two runs, against 18 of 18 for
the previous defaults. It cost **about 37%** as much and took **about 40%**
of the time. The one miss was later traced to a faulty test case. It also
reported **4 to 6** findings outside the known bugs per run, against 20 for
the previous defaults.

Cheaper configurations without reading tools for the detector cost as little
as 18% of the previous defaults. But in every run they missed the bugs whose
cause lies outside the changed lines: the same 2 in both runs, plus the one
deep case that needs another file in the run that included it. We kept the detector's
reading tools and limited how long it may use them.

## Why measure

The plan deferred cost ("Cost and latency are out of scope for the MVP",
`code-review-plan.md`, Decisions). Traced reviews then showed that cost and
time matter in practice: about $0.70 and several minutes per review, with
detectors leaving the change and reading unrelated code
(`REVIEW_LEARNINGS.md` §3.2). The same document asked for an evaluation set
with known defects (§3.3). The research recommends offline evaluation by
matching known facts, not by text similarity (research implication 8, §5).
The benchmark under `apps/tackle_cli/bench/review_eval` is that evaluation
set.

## Method

### Benchmark

`bench/review_eval.exs` runs real reviews (`Tackle.Review.run/2`) with the
user's configuration, credentials, and models. For each case it:

1. checks out a past commit of this repository in a scratch clone,
2. folds the seeded bugs into that commit, so the reviewed range looks like
   the original commit with the bugs in it,
3. removes everything that could reveal the seed, such as refs, reflogs,
   and the seed commit itself.

Each variant then reviews the same range from an ephemeral scope composed the
way `tackle review` composes it.

The recorded runs passed `--concurrency 4`. At the time, `tackle review` and
`/review` defaulted to 2 runs in flight and only the `review_changes` tool used
4. Since 2026-10-14 every entry point defaults to the requester's
`max_children_per_agent` (4 in sessions), so the timings now match all of them.

A finding **matches** a seeded bug when it points at the new side of the
same file and its lines overlap the bug's lines within 3 lines of slack. A
case may list other acceptable places, such as the crash site. Testing
findings never match a functional bug.

For each run, every bug gets one outcome:

- `shown`: in the final result;
- `rejected`: a candidate matched, and the verifier rejected it;
- `dropped`: a filter or the ranking removed it;
- `missed`: the detector never reported it.

**Extra** findings are shown findings that match no seeded bug. The cases do
not list every real problem, so this counts noise, not false positives.

**Cost** is the estimate `Tackle.Lib.LLM` derives from the adapter's price
card (USD per million tokens, cached reads at their own rate). Treat it as a
relative unit: the Codex provider bills by subscription.

### Cases

| case | commit | changed lines | seeded bugs |
|---|---|---|---|
| `multi-settle-interrupted-tools` | `8715e34` | 415 (8 files) | recovery not cleared on abandon; `begin_turn/4` drops `:continue`; tool-call lookup by string keys only; *swallowed persistence error (removed later, see below)* |
| `multi-native-clipboard` | `1f06c66` | 512 (23 files) | clipboard error collapsed to "no image"; terminal fallback disabled; unconfirmed copy reported as success; runtime dependency marked `only: :dev` |
| `multi-review-failed-runs` | `7ffadf2` | 645 (20 files) | timeout loses the transcript; wrong incomplete-unit boundary; `done` default read as `false`; wrong verifier error reason |
| `multi-watchdog-icons` | `638e3dc` | 269 (9 files) | first instead of last line; swapped registry lookup key; `or` instead of `and` |
| `deep-catalog-self-call` | `6b94d91` | 193 (3 files) | `Projection.metadata/1` calls `Session.Catalog.get/1`, but the catalog calls `Projection.metadata/1` inside its own rebuild callbacks: a GenServer calling itself through another module |
| `deep-meter-lost-update` | `d5b7c1d` | 44 (3 files) | the workflow meter's atomic `:ets.update_counter/4` replaced by a lookup and an insert, while every parallel run writes the shared total |
| `deep-watchdog-decision-leak` | `638e3dc` | 271 (9 files) | `Task.shutdown/2` on a decision timeout replaced by `Process.demonitor/2`, which leaves the task running |

The `multi-*` cases put several independent bugs into one commit. The
research shows recall collapsing on changes with many issues (S6: 38% for
one issue, 9% for five or more, §4). The `deep-*` cases put in one bug whose
cause lies outside the diff, such as process boundaries or concurrency. They
test what a detector limited to the diff gives up. Each case's JSON file
documents its seeds and why each one is a bug.

### Variants

All variants are transformations of the scope's review profiles; nothing in
the harness changes (`Tackle.Bench.ReviewEval.Variant`).

| variant | detector | verifier | thinking |
|---|---|---|---|
| `baseline` (run 1) | full prompt (17.4 KB), `read`/`bash`, 40 steps | full prompt (16.0 KB), 25 steps | session (`high`) |
| `baseline` (run 2) | lean prompt (2.4 KB), `read`/`bash`, 40 steps | lean prompt (1.1 KB), 25 steps | session (`high`) |
| `single-call` | no tools but `report_findings`, 3 steps, judges only the rendered diff and enclosing function | as baseline | session (`high`) |
| `combined` | as `single-call` | lean, 6 steps | `low` |
| `combined-no-tests` | as `single-call`, and told not to claim missing tests | lean, 6 steps | `low` |
| `capped-detector` | lean, `read`/`bash`, 6 steps, told to spend at most 5 rounds on code its findings depend on | lean, 6 steps | `low` |

All runs used `openai-codex/gpt-6.1-sol` for every stage, review profile
`default`, and 4 runs in flight per review. The scorer follows the
verifier's model and thinking level.

## Results

### Run 1 (2026-10-13): a detector without tools

4 `multi-*` cases, 15 bugs. File: `results-20261013T214217245385Z.jsonl`.

| variant | shown | cost | detector | verifier | verifier runs | prompt tokens | output tokens | time | extra |
|---|---|---|---|---|---|---|---|---|---|
| baseline | 15/15 | 3.19 | 1.80 | 1.30 | 32 | 7.90 M | 62.9 k | 817 s | 13 |
| single-call | 12/15 | 1.33 | 0.40 | 0.87 | 21 | 2.35 M | 30.0 k | 414 s | 5 |
| combined | 13/15 | 0.67 | 0.27 | 0.38 | 19 | 0.82 M | 12.4 k | 211 s | 3 |

Both tool-less variants missed `swallowed-clipboard-error` and
`incomplete-unit-boundary` in detection. Seeing either bug takes code that
is not in the diff:

- `swallowed-clipboard-error`: the error shapes of `Clipboard.read_image/0`
  in `clipboard_ex`;
- `incomplete-unit-boundary`: what samples and incomplete runs mean in
  `detector.ex`.

`single-call` also lost `repair-swallows-persistence-error`, which the
verifier rejected.

The stored outcomes in this file mark two of these misses as `rejected`.
That came from a scorer bug, fixed after the run: an "add tests" finding next
to a bug counted as a match. Testing findings no longer match functional
bugs, and the counts of shown bugs are unchanged.

Most of the verifier runs in the tool-less variants went to "the change has
no tests" findings. The detector cannot see tests, and the verifier, which
can, rejected these claims.

### Run 2 (2026-10-14): lean defaults, reading within a budget, deep cases

All 7 cases, 18 bugs. File: `results-20261014T082645621880Z.jsonl`. The
review stages already had lean prompts, so this `baseline` is lean.

| variant | shown | multi (15) | deep (3) | cost | detector | verifier | verifier runs | rejected | prompt tokens | time | extra |
|---|---|---|---|---|---|---|---|---|---|---|---|
| baseline | 18/18 | 15 | 3 | 5.00 | 2.70 | 2.18 | 43 | 2 | 8.89 M | 1555 s | 20 |
| capped-detector | 17/18 | 14 | 3 | 1.80 | 1.08 | 0.66 | 30 | 1 | 2.20 M | 695 s | 6 |
| combined | 15/18 | 13 | 2 | 1.25 | 0.48 | 0.71 | 24 | 9 | 1.15 M | 515 s | 3 |
| combined-no-tests | 15/18 | 13 | 2 | 0.89 | 0.44 | 0.39 | 18 | 0 | 0.84 M | 467 s | 3 |

Both tool-less variants again missed `swallowed-clipboard-error` and
`incomplete-unit-boundary`, and they also missed `catalog-calls-itself`.
`capped-detector` found all three. Its one loss was
`repair-swallows-persistence-error`, rejected by the verifier, the same bug
`single-call` lost in run 1.

No detector unit failed or stopped short in any variant. Four verifier runs
hit the 6-step limit before giving a verdict: 2 of 30 in `capped-detector`,
1 in `combined`, and 1 in `combined-no-tests`. Their findings were kept as
`uncertain`; none of them was a seeded bug. The previous verifier limit of 25
was never reached.

### Run 3 (2026-10-14): `capped-detector` again

The same 7 cases. File: `results-20261014T100611965295Z.jsonl`.

| variant | shown | multi | deep | cost | detector | verifier | verifier runs | rejected | prompt tokens | time | extra |
|---|---|---|---|---|---|---|---|---|---|---|---|
| capped-detector | 18/18 | 15 | 3 | 1.87 | 1.01 | 0.78 | 30 | 0 | 2.24 M | 595 s | 4 |

This time the verifier confirmed `repair-swallows-persistence-error`.

## Findings

### 1. The number of steps drives cost, not the length of the system prompt

Every step of an agent run sends the whole conversation again, including
every file it has read. In run 1, baseline sent 7.9 M prompt tokens for
63 k output tokens, about 125 to 1.

Making the prompts lean cut the system prompts by 86% to 93% (detector
17.4 KB to 2.4 KB, verifier 16.0 KB to 1.1 KB). On the same 4 cases, baseline's prompt tokens fell
21% (7.90 M to 6.26 M). Its cost did not fall (3.19 to 3.59), which is
within run-to-run variance (see 7). Cutting the steps and the thinking
cut cost by about 63%.

The lean prompts are still adopted, for a reason other than cost. `AGENTS.md`
guides agent loops and chats, not reviews. A convention a review should
enforce belongs in a review rule (`Tackle.Review.Rules`). This matches the
research: curated rules are the large lever, and generic context adds
little (S1, S5, S7, §3).

### 2. The detector needs to read beyond the diff, but only a little

A detector that sees only the diff and the enclosing function was the
cheapest configuration. But across both runs it missed the same three bugs,
each needing knowledge from another file:

- the error shapes of a library call;
- the meaning of a counter defined elsewhere;
- the process that calls a function.

A detector allowed up to 5 rounds of reading, and told to read only what a
suspected finding depends on (callers, callees, definitions), found all
three in both runs.

This matches the research. Missing context causes most false positives
(S6: 48%). Targeted context beats both the raw diff and more context (S2).
Letting the model ask for the functions it needs raised acceptance (S13).
All of these are in §6. A capped agentic detector is that targeted,
on-demand context, with a bounded cost. It also keeps the plan's principle
of a deterministic orchestrator with agents only inside one unit
(`code-review-plan.md`, Design principles; Bugbot's gain from one agentic
reviewer, §11). And it limits the wandering seen in traced reviews: network
searches and `/nix/store` reads (`REVIEW_LEARNINGS.md` §3.2).

### 3. Short verifier runs lose nothing measurable

With 6 steps instead of 25, the verifier reached a verdict in 56 of 60
`capped-detector` runs (runs 2 and 3); the other 4 runs across all 6-step
variants of run 2 hit the limit, on findings that were not seeded bugs. The
verifier reports its verdict before any explanation (the plan's
verdict-first principle, S1, §2), so a short run is enough when the
finding names a concrete trigger. A verifier that runs out of steps keeps
its finding as `uncertain` and records the failure, instead of rejecting it
(`Tackle.Review`, Failed runs), so a shorter limit shows up in the result
rather than silently turning into a rejection.

### 4. Lower thinking showed no measurable loss

The measured configuration ran the detector, verifier, and scorer at `low`
instead of `high` and found the same bugs. The step limits and the thinking
level changed together, so their individual effects are not separated
(see Threats to validity). This is consistent with the research, though not
proof of it:

- model choice is secondary to pipeline design (S12, S16, §12);
- longer reasoning tends to add false defect claims and latency rather than
  precision (S1, S14, S15, §8).

The right level depends on the model. It is therefore a per-user setting
(`review.thinking`) and not a built-in default.

### 5. Precision improved along with cost

Findings outside the known bugs fell from 20 (baseline, run 2) to 6 and 4
(`capped-detector`, runs 2 and 3). The cases do not list every real
problem, so this is noise, not a false-positive rate. Still, it points the
same way as the strongest finding of the research: noise destroys adoption,
and precision matters more than volume (S1, S4, S5, S13, §1).

### 6. A detector that cannot see tests should not claim missing tests

The tool-less detector reported "behaviour X is not tested", which the
verifier, which can read the tests, mostly rejected. Telling it not to make
such claims (`combined-no-tests`) found the same bugs as `combined`:

- 28% lower cost overall (1.25 to 0.89);
- 45% lower verifier cost (0.71 to 0.39);
- no rejections, against 9.

The adopted detector can read tests, so this does not apply to the
defaults. It shows the cost of unverifiable claims. It is the starting
point for a cheaper "quick" review mode.

### 7. Single runs are noisy, in recall and in cost

- **Recall.** The same configuration found 17 and then 18 of 18 bugs; the
  difference was one verifier decision on a borderline case.
- **Cost.** `combined` on the same 4 cases cost 0.67 in run 1 and 0.99 in
  run 2. Baseline cost 3.19 and then 3.59.

Differences under about 30% in cost, or 1 to 2 bugs in recall, are not
evidence. The research reports the same instability: little overlap between
repeated runs of one model (S6, §7).

### 8. Benchmark cases need the same scrutiny as the reviewer

The bug the verifier rejected twice, `repair-swallows-persistence-error`,
was a weak case. A failed journal append stops the journal, so the repair
fails later anyway. It does not report success as the case claimed. The
verifier was right. We removed that seed. `multi-settle-interrupted-tools`
now has 3 bugs, and the suite has 17.

Two of the three `deep-*` cases were not deep for this model: every
variant caught the meter race and the watchdog leak from the diff alone.
Only `deep-catalog-self-call` separated the variants. The plan expected
verifier over-rejection (S2) to be a tuning concern (Decisions). In these
runs the only over-rejection was a case error.

## Decision and alternatives

**Adopted.** Lean prompts (`instructions: false`), 6-step limits for the
detector and verifier, and a step budget in each detector run's prompt that
tells it how many rounds of tool calls it has and to read only what a
finding depends on (`Tackle.Review.Detector.step_budget/1`). The budget
follows `review.max_steps` when a user changes the limits.

`low` thinking is recommended, not built in:

```json
{ "review": { "thinking": { "detector": "low", "verifier": "low", "scorer": "low" } } }
```

**Not adopted:**

- **`single-call`, `combined`:** too cheap to ignore, but they lose bugs
  whose cause lies outside the diff, consistently and for a structural
  reason.
- **`combined-no-tests`:** the cheapest configuration that kept the
  tool-less variants' recall. It is a candidate for an explicit quick mode,
  not for the default.
- **Repeated sampling** (`:samples`) was not measured here. The research
  supports it with aggregation (S6, §7), at a multiple of the cost.

## Threats to validity

- **Small sample.** 18 seeded bugs (17 after the fix), one or two runs per
  configuration, and only one run of the previous defaults on the full set.
- **One model and provider.** The step budget and thinking level may behave
  differently on other models; repeat the benchmark when changing models.
- **Confounded changes.** Step limits and thinking level changed together
  in the measured configuration. The adopted defaults leave thinking
  unchanged unless `review.thinking` is set, and that combination was not
  measured.
- **Seeded bugs in our own code.** The same people and agents wrote the
  cases and designed the variants. Seeds are single-site edits, which may be
  easier to find than real defects. The `hist-*` cases, real bugs fixed by
  later commits, were not part of these runs.
- **Matching by location.** A finding at the right line with the wrong
  explanation counts as found, and a correct finding outside the listed
  places counts as missed.
- **Provider caching.** Variants run back to back can reuse each other's
  cached prompt prefixes. The runner rotates the variant order per case
  and repeat to spread the effect.

## Reproducing

```sh
cd apps/tackle_cli
mix run --no-start bench/review_eval.exs --check        # validate the cases, no model calls
mix run --no-start bench/review_eval.exs \
  --case multi-settle-interrupted-tools --case multi-native-clipboard \
  --case multi-review-failed-runs --case multi-watchdog-icons \
  --case deep-catalog-self-call --case deep-meter-lost-update --case deep-watchdog-decision-leak \
  --variants baseline,low-thinking --concurrency 4 --repeat 2
```

With the current defaults, `low-thinking` is the measured `capped-detector`
configuration. The only difference is that the budget instruction is now part
of each detector run's prompt rather than of its system prompt. `baseline` is
the new defaults at the session's thinking level. Results recorded before
the changes have a 40/25-step baseline (and, in run 1, full prompts). The
results files of runs 1 to 3 are named above. Each line holds every finding,
the stage usage, and the settings, so the runs can be analysed again without
new model calls (`--summarize FILE`).

## Follow-ups

- Measure the previous defaults (40 and 25 steps) a second time, through a
  variant or `review.max_steps`, so their variance is known too.
- Add the single-bug `seed-*` and the historical `hist-*` cases to the
  regular comparison (7 more bugs).
- Replace the two shallow `deep-*` cases with bugs whose cause is only
  visible in another file.
- Measure the step-limit and thinking effects separately, and measure the
  adopted defaults without `review.thinking`.
- Watch how often verifiers hit the 6-step limit (`summary.verification_failures`);
  2 of 60 in the adopted configuration. If it grows, 8 steps is the next
  candidate.
- Evaluate a quick review mode built on `combined-no-tests`, and repeated
  sampling for an assertive mode (S6, §7).
- Consider precomputed context, such as the definitions the changed lines
  call, as a cheaper alternative to reading tools (S2, §6).
