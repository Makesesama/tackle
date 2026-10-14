# Review benchmark (option A: fewer tokens per run)

**Live benchmark, not a synthetic baseline.** It runs real reviews
(`Tackle.Review.run/2`) with your configuration, credentials, and models, and
each review costs what a normal `tackle review` of the same range costs. It
compares review configurations ("variants") by cost (tokens, runs, wall
time) and quality (known issues found).

```sh
cd apps/tackle_cli
mix run --no-start bench/review_eval.exs --check            # validate the cases, no model calls
mix run --no-start bench/review_eval.exs --list-variants
mix run --no-start bench/review_eval.exs                     # default variants, every case, once
mix run --no-start bench/review_eval.exs --variants baseline,single-call \
  --case seed-png-row-off-by-one --repeat 3                  # a cheap first look
mix run --no-start bench/review_eval.exs --summarize /tmp/tackle-review-eval/results-….jsonl
```

All options are listed at the top of `bench/review_eval.exs`. Each run's
progress goes to standard error. At the end, a summary table per variant and a
per-case table go to standard output. Each review is also written as one JSON
line to `--out` (default: a new file under `<tmp>/tackle-review-eval/`). A line
holds the score, usage per stage, what each stage ran with (system prompt
size, tools, step limit), and the full JSON result with every finding, so you
can analyse it again later without paying for another run.

## How a run works

1. Each case is checked out under `--workdir` in a scratch clone that shares
   this repository's objects (`git clone --shared`; nothing is written to the
   repository itself). The seeded edits are amended into the case's commit,
   which keeps its original message. Nothing in the checkout gives the answer
   away: the directory name is opaque (the agents are told their working
   directory), there is no seed commit or message, and every branch, tag,
   remote, and reflog is deleted, so `git log --all` cannot reach the later
   fix of a historical case. The objects remain reachable through the shared
   object store, so an agent that went looking with low-level object commands
   could still find them.
2. For every repeat, case, and variant, an ephemeral scope is composed the
   way `tackle review` composes it. The scope's working directory is the
   clone, so the agents read the code under review and its AGENTS.md as of
   that commit. Then `base..seeded-head` is reviewed with history off. The
   checkout is reset (`git reset --hard`, `git clean -dfx`) before each run,
   in case an earlier run's bash calls changed it.
3. The variant's profile changes and options are applied
   (`Tackle.Bench.ReviewEval.Variant`). Nothing in the harness changes.
4. Findings are matched against the case's issues
   (`Tackle.Bench.ReviewEval.Score`): same file, new side, line overlap within
   `--slack` lines (default 3) with the issue or one of its `also` locations,
   and optional keywords. Each issue is assigned
   to the stage that lost it: `shown`, `rejected` (by the verifier),
   `dropped:<reason>` (by the filters or ranking), or `missed` (the detector
   never reported it).

## Variants

| name | change |
|---|---|
| `baseline` | current defaults |
| `steps` | A2: step limits detector 10 (default 40), verifier 6 (default 25) |
| `lean` | A3: system prompt is only the assignment and the working directory: no AGENTS.md, no skills (and no skill tool) |
| `lean-agents` | A3: assignment plus AGENTS.md, no skills |
| `low-thinking` | A4: thinking `low` for detector and verifier (the scorer follows the verifier) |
| `single-call` | A1: detector without tools except `report_findings`, at most 3 steps, judging only from the unit's rendered diff and function context; verifier unchanged |
| `single-call-agents` | A1 with AGENTS.md in the detector prompt |
| `combined` | A1 + lean verifier with 6 steps + thinking low |
| `cheap-detector` | A4: detector on `--cheap-model REF` (only with that flag) |

`low-thinking` only differs from `baseline` when the root model (`--model`
and `--thinking`, or your configuration) is not already at `low`. If the root
thinks less than that, `low-thinking` costs more. Each record's `settings`
hold the model and thinking level every stage actually used.

## Reading the results

- **recall** counts shown findings that match an issue. **detected** counts
  matches at any stage. The gap between them is the verifier and the filters.
  Both are over the issues of every run: a failed run (see **err**) finds
  nothing. Its tokens are unknown, so it is left out of the token and time
  means.
- **extra/run** is the number of shown findings that match no known issue.
  The issue lists are not exhaustive, so this is a noise proxy, not a false
  positive count. Compare it between variants on the same cases.
- **prompt tok** includes cached tokens. **uncached** is input plus cache
  writes. Providers bill these very differently, so look at both, and at
  **cost** when the adapter reports one.
- **time s** is the review's own duration (`summary.duration_ms`), without
  scope setup; records also keep the wall time (`wall_ms`). It depends on
  `--concurrency`. Without it a review runs 2 runs at a time, as `tackle
  review` does.
- Providers cache prompt prefixes for a few minutes, so a variant that runs
  right after another one with the same prompts can see cache hits the other
  one paid for. To spread that effect, each case and repeat runs the variants
  in a different rotation instead of always the same order.
- LLM reviews are noisy, and seven cases with one issue each is a small
  sample. Use `--repeat 3` or more before trusting a difference of one issue.

## Cases

`bench/review_eval/cases/*.json`. The format is documented in
`Tackle.Bench.ReviewEval.Case`. `seed-*` cases inject one bug into lines a
real commit added. `hist-*` cases review a real commit whose bug a later
commit fixed (named in the description). Run `--check` after adding or
editing a case: it prepares every case, prints its size (units and detector
runs at the default unit size), and fails when an issue is not on a changed
line, since no finding could point there.

## Jail

Under the jail (`TACKLE_EXEC_LAUNCHER` set), the jail workspace is fixed when
the first scope starts. Either set `TACKLE_EXEC_WORKSPACE` to a directory that
contains `--workdir`, or run without the jail; the review agents only read.

## Tests

The modules under `bench/review_eval/lib` are compiled in the test
environment and covered by `test/tackle_cli/review_eval_test.exs`. That
includes an end-to-end run against a scripted provider which checks what each
variant's detector is actually sent.
