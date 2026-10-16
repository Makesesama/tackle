# Review package plan: `packages/tackle_review`

**Status: phases 1 to 3 are implemented; phases 4 and 5 are a plan.** The review
pipeline still lives in `packages/tackle` (`Tackle.Review.*`); see
[`code-review-plan.md`](code-review-plan.md) for how it works.

## Goal

Make code review a package that any host can embed: the harness and CLI
today, and a GitHub review bot (and later a web app) that keeps its state in
a database instead of files under `TACKLE_HOME`.

## Principle

`tackle_review` owns the review logic. It does not store anything and does
not decide where data comes from. Everything that touches storage or the
local machine is either an **input** to a review or part of its **output**.
The host loads and stores those values.

| Concern | Today | In the package |
|---|---|---|
| Known findings | `Review.run` read them from `History` | input: `:known_fingerprints`, fingerprints dropped as `:known` |
| Recording a run | `Review.run` wrote `History` | output: the `Result`, with rule and prompt digests; the host records it |
| Rules | discovered from `TACKLE_HOME` and `.tackle/review/rules` through the executor | input: `:rules`, parsed rules (default: the built-in rules); the package provides the parser, the built-in rules, and precedence merging |
| Settings | read from the requester's session context (`:review_settings`) | input: `:settings` (`Tackle.Review.Settings`) |
| Change | loaded from the working tree | input: a `Change`, loaded from a working tree or from two commits in a clone (both through `gix_ex`) |
| Model, thinking, and step limit per stage | edits `%Tackle.Config{}` directly | through the runtime's `AgentBackend` (see below); the only call into the host during a run |

`Tackle.Review.Finding.fingerprint/2` stays in the package: a stable
fingerprint is part of a finding, while storing it is the host's job.

The only call into the host during a run is the stage configuration. The
pipeline starts subagent runs with a different model, thinking level, step
limit, and per-run context for each stage, and it calls the scorer model
directly. Those are operations on agent specs, and `tackle_runtime` already
abstracts agent specs per backend (`Tackle.Runtime.AgentBackend`;
`tackle_phoenix` has a second backend with its own config type). They become
backend callbacks.

## Dependency graph

```
tackle_lib ◄── tackle_runtime ◄── tackle_review (+ gix_ex)
                                       ▲
                                 tackle (harness) ◄── tackle_cli
                                       
GitHub bot / web app ──► tackle_runtime + tackle_review (+ own backend, database)
```

Because the package depends on neither the harness nor any storage, the
harness can depend on it. The harness keeps the review integration for local
use: the `review_changes` tool, the file-based history, reading rules from
disk, and the `review` section of `config.json`. A database-backed host does
not use the harness for review at all.

## What goes where

### `packages/tackle_review` (`:tackle_review`, `Tackle.Review.*`)

- The pipeline: `Tackle.Review` and the pure modules (`Diff`, `Change`,
  `Units`, `FunctionContext`, `Finding`, `Cluster`, `Filter`, `Rank`,
  `Scorer`, `Result`, `Locations`, `Confinement`, `Glob`, `Pool`, `Detector`,
  `Verifier`, `Delegation`).
- `Tackle.Review.Rules` (phase 3): parsing, built-in rules (compiled in),
  `load/2` (precedence merging of the files a host read, by source), and
  resolving rules per unit, without file discovery. `read_tree/3` reads
  `.tackle/review/rules` at a commit through `gix_ex` (`GixEx.read_dir/4`,
  added for it), so a host without a working tree (the bot) can read a
  repository's rules.
- `Tackle.Review.Settings` (phase 3, from `Tackle.Config.Review`): the
  settings struct and its validation, including `from_json/1` for the JSON
  form of `config.json`'s `review` object, so every host accepts the same
  format.
- `Tackle.Review.Stages` (phase 3): the `review-detector` and
  `review-verifier` profiles as plain data (name, description, prompt, tool
  names, step limit). Hosts build their own agent specs from it.
- `Tackle.Review.Tools.ReportFindings` and `Tackle.Review.Tools.ReportVerdict`
  (from `Tackle.Tools.*`): already plain `Tackle.Lib.Tool`s that read their run
  data from the session context.
- Dependencies: `tackle_lib`, `tackle_runtime`, `gix_ex`, `yaml_frontmatter`.
  The `gix_ex` dependency moves out of the harness, which gets it through this
  package.

### `packages/tackle_runtime`

Optional `Tackle.Runtime.AgentBackend` callbacks (implemented in phase 2),
exposed through `Tackle.Runtime` so that callers never see the config type:

- `configure/2` (`Tackle.Runtime.configure_spec/3`) with `:model`,
  `:thinking`, `:max_steps`, `:context` (merged into the session context),
  and `:llm_opts` (merged, for `:prompt_cache_key`);
- `describe/1` (`Tackle.Runtime.describe_spec/2`) returning the model
  reference, thinking level, step limit, system prompt, and tool names;
- `llm/1` (`Tackle.Runtime.spec_llm/2`) returning the model client and its
  options with credentials resolved, for the scorer's direct model call;
- `Tackle.Runtime.prepare_spec/2`, which resolves a `model_source: :parent`
  spec against the requester before a run starts, through the existing
  `prepare_child/2`.

A backend without a callback returns
`{:error, {:unsupported_backend_callback, name}}`, and the review fails with
`{:unsupported_agent_config, profile, reason}` before any run.

### `packages/tackle_lib`

Implemented in phase 2:

- `Tackle.Thinking` moves to `Tackle.Lib.Thinking`. It is provider-neutral and
  only holds the level vocabulary and the `:reasoning_effort` mapping.
- (`Tackle.Skills.Frontmatter` first moved here as `Tackle.Lib.Frontmatter`;
  see `packages/yaml_frontmatter` below.)

### `packages/yaml_frontmatter`

Implemented after phase 2: the Markdown front matter parser, formerly
`Tackle.Skills.Frontmatter`, as the dependency-free `YamlFrontmatter`. Skills,
agent definitions, and review rules all read their front matter with it, so
`tackle_review` depends on it rather than on skills code or `tackle_lib`.

### `packages/tackle` (harness)

Keeps the local integration and depends on `tackle_review`. Since phase 1,
`Tackle.LocalReview` wraps `Tackle.Review.run/2` with the local settings,
rules, and history; the `review_changes` tool, `tackle review`, and the TUI
review call it.

- `Tackle.Tools.Review` (`review_changes`): loads the change from the agent's
  workspace, resolves rules from disk, reads and writes the file history,
  and calls `Review.run` with plain options.
- The file history (today's `Tackle.Review.History`, renamed into the
  harness namespace, for example `Tackle.ReviewHistory`), with the same
  JSONL format under `$TACKLE_HOME/review/`.
- Rule discovery from `$TACKLE_HOME/review/rules` and `.tackle/review/rules`
  through the executor (`Tackle.LocalReview.Rules`, phase 3), loaded with
  `Tackle.Review.Rules.load/2`.
- `config.json`'s `review` object, validated by `Tackle.Review.Settings`.
- `Tackle.Agents.Default` builds the two stage definitions from
  `Tackle.Review.Stages`, so `.tackle/agents/review-*.md` overrides keep
  working; `Tackle.Tools.review/0` lists the package's output tools.
- `Tackle.Runtime.RootBackend` implements the new backend callbacks.
- The general `reviewer` subagent stays as it is; it is not part of the
  pipeline.

### `apps/tackle_cli`

`tackle review` and the TUI review use the harness's history and rule
discovery as they do now, with updated module names. No user-visible change.

## Result changes

`Tackle.Review.Result` carries what only the run knows and a host needs to
record a run (implemented in phase 1): `summary.rules`, the rules in effect
(`id`, source, status, and a content digest), and `summary.prompts`, the
stage prompt digests by profile name.

## Phases

Each phase leaves every affected package compiling with
`--warnings-as-errors`, formatted, and with passing tests. The physical move
comes last, after the review code no longer uses the harness, so moving it
only changes file paths and module names.

1. **Inputs and outputs.** *Implemented.* `Review.run` no longer takes
   `:history` or `:skip_outcomes`; known findings come in through the
   existing `:known_fingerprints`, and `result.summary` carries `rules` and
   `prompts` digests that `History.record_run/3` writes. Settings come in
   as `:settings` instead of being read from the requester's context, rules
   default to the built-in ones (`Tackle.Review.Rules.builtin/1`), and
   `:warnings` adds the host's warnings to the summary. The harness's
   `Tackle.LocalReview` reads the requester's settings, discovers rules
   through the session executor, and reads and writes the history; the
   `review_changes` tool, `tackle review`, and the TUI use it. The review
   benchmark code is removed (see "Breaking changes").
2. **Runtime contract.** *Implemented.* The backend callbacks above are in
   `tackle_runtime` and implemented by `RootBackend`; `Tackle.Review`,
   `Tackle.Review.Delegation`, and the detector and verifier use them and no
   longer read `%Tackle.Config{}` or `Tackle.Auth`. `Thinking` moved to
   `tackle_lib`, and `Frontmatter` to `packages/yaml_frontmatter`.
3. **Stages and rules.** *Implemented.* `Tackle.Review.Stages` holds the
   stage profiles as data, and `Tackle.Agents.Default` builds its two
   definitions from it (the `Tackle.Agents.Default.ReviewDetector` and
   `ReviewVerifier` modules are gone). `Tackle.Config.Review` is now
   `Tackle.Review.Settings`, with `from_json/1` taking over the JSON parsing
   from `Tackle.Config.File`. `Tackle.Review.Rules` lost `discover/1` to the
   harness's `Tackle.LocalReview.Rules` and gained `load/2`, `project_dir/0`,
   and `read_tree/3`, backed by the new `GixEx.read_dir/4`. The pipeline now
   uses no harness module except the output tools under `Tackle.Tools` and
   `Tackle.Review.History`, both handled in phase 4.
4. **Move.** Create `packages/tackle_review`, move the modules and their
   tests (with a copy of the Git test helper), make the harness depend on
   it, and remove `gix_ex` from the harness. Regenerate the Nix dependency
   files, add the package to `nix/packages/default.nix`, add a Woodpecker
   job, and update `AGENTS.md`, the READMEs, and `code-review-plan.md`.
5. **GitHub review bot**, a separate plan: a new app on `tackle_runtime` and
   `tackle_review` with its own backend and database.

## Breaking changes

- `Tackle.Config.Review` → `Tackle.Review.Settings`;
  `Tackle.Review.Rules.discover/1` → `Tackle.LocalReview.Rules.discover/1`;
  `Tackle.Agents.Default.ReviewDetector`/`ReviewVerifier` → `Tackle.Review.Stages`;
  `Tackle.Tools.{ReportFindings,ReportVerdict}` →
  `Tackle.Review.Tools.*`; `Tackle.Review.History` → harness namespace;
  `Tackle.Thinking` → `Tackle.Lib.Thinking`;
  `Tackle.Skills.Frontmatter` → `YamlFrontmatter` (`packages/yaml_frontmatter`).
- `Review.run/2` options: `:history` and `:skip_outcomes` are removed (use
  `:known_fingerprints`, or `Tackle.LocalReview`); `:settings` and
  `:warnings` are new, and without `:rules` only the built-in rules apply.
  `History.record_run/3` takes no options.
- New optional callbacks on `Tackle.Runtime.AgentBackend`.
- The `config.json` format, the history files, and the `tackle review`
  command do not change.
- The review benchmark is not ported. Phase 1 removes its code
  (`apps/tackle_cli/bench/review_eval.exs`, `bench/review_eval/lib`,
  `bench/review_repro.exs`, `test/tackle_cli/review_eval_test.exs`, and the
  `elixirc_paths` entry in the CLI's `mix.exs`). The cases in
  `bench/review_eval/cases` stay as input for a later rewrite as standalone
  scripts; the removed code remains in Git history.

## Risks and decisions

- **Rules for pull requests come from the base commit, not the head.**
  Otherwise a pull request can change the rules it is reviewed against.
  Reading rules from a commit (phase 3) makes this possible for the bot; the
  CLI keeps reading the working tree, where the user is the author.
- **A chat feature in a web app** needs its own host on `tackle_runtime`, as
  `tackle_phoenix` has. Harness parts such as tools, the executor, and auth
  may then need extracting the same way. This plan does not do that, and
  nothing in it blocks it.
- **Backend callbacks are the one real contract change.** They are optional
  so `tackle_phoenix` and other backends keep working unchanged; review is
  only available on backends that implement them.
