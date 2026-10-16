# tackle_review

Code review on [`tackle_runtime`](../tackle_runtime/README.md):
`Tackle.Review.run/2` takes a change and returns ranked, line-anchored
findings (`Tackle.Review.Result`). Experimental.

A deterministic pipeline splits the change into small units, runs detector
agents on them, filters and verifies the candidates with verifier agents,
recalibrates their confidence, and ranks what is left
(see `Tackle.Review`). Only the detector and verifier stages are agents;
they run as delegated runs of the requester's scope, so the scope supplies
concurrency limits, cancellation, and visibility.

## What a host provides

The package stores nothing and reads no configuration of its own. A host
passes in:

- **the change** - `Tackle.Review.Change.load/1` reads it from a working
  tree (branch, staged, or range) with [`gix_ex`](../gix_ex/README.md);
- **the requester and profiles** - an agent of a runtime scope, and the
  `review-detector` and `review-verifier` agent specs, built from
  `Tackle.Review.Stages` with the output tools
  `Tackle.Review.Tools.ReportFindings` and `ReportVerdict`;
- **rules** - `Tackle.Review.Rules.load/2` merges the built-in rules with
  rule files the host read; `Rules.read_tree/3` reads a repository's rules
  at a commit, for example a pull request's base;
- **settings** - `Tackle.Review.Settings`, with `from_json/1` for the
  `review` object of `config.json`;
- **known findings** - fingerprints of findings not to report again.

It records the returned `Result` however it likes; the summary carries
digests of the rules and prompts in effect.

The scope's runtime backend must implement the optional
`Tackle.Runtime.AgentBackend` callbacks `configure/2`, `describe/1`, and
`llm/1`, which the review uses to give each stage its model, thinking level,
step limit, and per-run context, and to call the scorer's model. The
harness's `Tackle.Runtime.RootBackend` implements them, and so does the test
backend in `test/support/backend.ex`, which runs `Tackle.Lib` loops directly
and shows the smallest host a review needs.

The harness (`packages/tackle`) is one host: `Tackle.LocalReview` adds the
local session's settings, rules discovered under `$TACKLE_HOME` and
`.tackle/review/rules`, and a file history, and the `review_changes` tool,
`tackle review`, and the TUI's `/review` use it.

## Development

`gix_ex` needs a Rust toolchain (`cargo`), and `tackle_lib`'s rebar3
dependencies need the dev shell's `rebar3` (`MIX_REBAR3`):

```sh
mix deps.get
mix compile --warnings-as-errors && mix test
mix format --check-formatted
```

Tests use fake adapters and the test backend; they need no credentials or
model calls.
