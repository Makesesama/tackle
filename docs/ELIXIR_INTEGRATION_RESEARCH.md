# Elixir integrations for the harness and review: research and plan

Status: **research notes and plan.** Of the "Plan", only the gate seam and
the compile gate (`packages/tackle_elixir`) are implemented; the rest is a
proposal. The goal is to make `tackle_cli` and `tackle_review` the best
agent harness and review tool for Elixir while keeping other languages
working. We integrate with Tidewave and Expert instead of competing with
them.

This document records what published evidence says about giving coding
agents language tooling (language servers, type checkers, runtime tools),
what that means for Elixir, and the order in which we build and measure.
Related documents:

- [`code-review-research.md`](code-review-research.md) and
  [`code-review-benchmark.md`](code-review-benchmark.md): the review
  pipeline's evidence and its current benchmark.
- [`PLUGINS.md`](PLUGINS.md): how optional plugins are enabled.

## Summary

Language tooling helps agents when it runs **as a deterministic check**,
not when it is offered **as another tool the model may choose**. The
strongest result is a blocking type check at the end of the agent's turn.
Navigation tools (definition, references, docs) only helped when the model
was told to use them and when grep could not answer the question.
Diagnostics pushed during the work were neutral, and telling the model to
fix every diagnostic made it worse.

For Elixir this points to, in order:

1. A parse guard on edits and a **compile gate** at the end of the turn.
2. A **small, prompted** set of lookup tools for code that grep cannot
   resolve (macro-generated functions, dependencies, protocols), taken from
   Tidewave or ElixirLS through MCP.
3. For review, analyzers run **by the pipeline** (compiler, Credo, Sobelow,
   xref), with their new findings verified by the LLM.

## Evidence

### Language servers for agents (Barber, 2026)

Ian Barber, "When Do Language Servers Help Coding Agents?", August 2026
([report](https://github.com/ianbarber/lsps-for-llms/blob/main/REPORT.md),
[blog post](https://ianbarber.blog/2026/08/11/lsps-for-llms/)). Seven local
and API models on Python with Pyrefly, against a baseline of grep, ranged
reads, and a shell; one operation added or withheld at a time.

- **Availability alone changed nothing.** Agents mostly did not call the
  offered LSP operations.
- **Prompted lookups helped a little, and only where retrieval was needed.**
  On tasks where the receiver's type had to be fetched, resolution was 70/75
  with text search, 71/75 with lookup available, and 75/75 with lookup
  prompted. With the source already in context, all arms were equal.
- **No token savings without substitution.** A definition span was cheaper
  than a ranged read (about 1.3×), but models re-read the defining file
  after 35 of 36 injected spans. Saying the span was complete removed 2
  re-reads. Only fine-tuning changed the behaviour.
- **A blocking check at submission was the clear win.** On 12 seeded
  defects that passed the visible test, bad drafts accepted went from 11/12
  (no checker) to 1/12 (type checker gating submission). It costs nothing
  on clean work.
- **Timing of diagnostics during the work did not matter.** Batched at the
  model's yield, after every edit, or live mid-stream: all within noise of
  no feedback (0.44–0.50 resolution).
- **Ordering the model to fix every diagnostic hurt**: 0.31 against 0.44
  with no feedback. Removing that one sentence recovered the loss.
- **Types help regardless of tools.** Removing annotations made text
  retrieval worse.

Limits: Python only, small synthetic tasks that fit in context, and the
timing experiment used a 7B model. Barber expects navigation tools to pay
off more on large, private codebases and where a type is reached through
generated code, stubs, compiled boundaries, or factories.

### Edit guardrails (SWE-agent, 2024)

SWE-agent ([arXiv 2405.15793](https://arxiv.org/abs/2405.15793), NeurIPS
2024) rejected edits that failed a linter. The guardrail added about 3
percentage points on SWE-bench. Same pattern: a check the model does not
have to choose.

### Structured code graphs (Codebase-Memory, 2026)

Codebase-Memory ([arXiv 2603.27277](https://arxiv.org/abs/2603.27277)): a
Tree-sitter knowledge graph over MCP reached 83% answer quality against 92%
for a file-exploration agent, at ten times fewer tokens. Cheaper tools can
give worse answers; measure the whole task, not one operation.

### Tool count

Every exposed tool costs schema tokens and makes selection harder. The
evidence is weaker here (practitioner reports and tool-retrieval work such
as RAG-MCP), but it argues for exposing a few tools rather than a server's
whole surface.

### Static analysis with an LLM verifier (Tencent, 2026)

"Reducing False Positives in Static Bug Detection with LLMs: An Empirical
Study in Industry" ([arXiv 2601.18844](https://arxiv.org/abs/2601.18844)):
on 433 alarms from an industrial analyzer, hybrid LLM and static-analysis
techniques removed 94–98% of false positives with high recall. This
supports analyzers as candidate generators and the LLM as verifier. A
review pipeline calls analyzers itself, so the tool-choice problem above
does not apply.

## What this means for Elixir

- **The compiler is the gate.** `mix compile` (with Elixir 1.20's type
  warnings) is authoritative and incremental, and plays the part of Pyrefly
  in Barber's gate experiment.
- **Navigation may help Elixir more than Python. This is a hypothesis.**
  Barber found lookups pay off where grep fails. In Elixir that is common:
  functions generated by `use` and other macros, Ecto schemas, Phoenix
  router helpers, Ash DSLs, protocol implementations, and code under
  `deps/`. Tidewave's Rails README makes the same argument about
  metaprogramming. We have to measure it.
- **Elixir has fewer annotations to read.** Without static types in most
  code, the model cannot type-check by reading as easily as with annotated
  Python. That may make both the gate and lookups more valuable. Also a
  hypothesis.

### Integration targets

| Project | Interface | Relevant capabilities | Fit |
| --- | --- | --- | --- |
| Tidewave (Phoenix, v0.9.1) | MCP, streamable HTTP at `/tidewave/mcp` in the running app | `project_eval`, `get_docs`, `get_source_location`, `get_logs`, `execute_sql_query`; browser tools can be excluded with `?include_browser_tools=false` | CLI with a running app that depends on Tidewave. Not hub review (no running app). |
| ElixirLS (v0.29+) | Experimental built-in MCP server | `find_definition`, `get_environment`, `get_docs`, `get_type_info`, `find_implementations`, `get_module_dependencies` | Static lookups without a running app. |
| Expert (0.1.0, March 2026) | LSP only; no MCP server found | Definitions, references, hover, compiler diagnostics | Later. Its diagnostics are cheaper as `mix compile`; navigation waits for the lookup experiment. |

Tackle reaches the MCP servers through `tackle_mcp`. We found no option there
to expose only selected tools of a server; the plan needs one (see below).

## Plan

### Design rules

1. **Checks over tools.** Language tooling runs as guards and gates, not as
   tools the model must remember to call.
2. **Gates are quiet when clean.** On failure they report only *new*
   diagnostics (against a baseline taken at turn start) in files the agent
   changed, and stop after a small number of repair rounds (2 to start).
3. **Report neutrally.** "The compile gate found 2 new errors in files you
   changed: …", never "you must fix every diagnostic".
4. **No live diagnostics.** Nothing is pushed after each edit or
   mid-stream, apart from the parse guard's rejection.
5. **Few tools, with instructions.** Expose only the lookup tools that
   answer what grep cannot, and say when to use them in a skill or system
   prompt line. Unprompted, they will not be used.
6. **Log every decision.** Gates record when they block, whether the repair
   passes, and when they block valid work. Lookup tools record calls and the
   reads that follow them.
7. **Review runs analyzers itself.** Compiler, Credo, Sobelow, and xref run
   on base and head; new results become candidates or detector context;
   the verifier decides.

### Pieces

1. **Parse guard.** `edit` and `write` reject `.ex`/`.exs` results that
   `Code.string_to_quoted/2` cannot parse, with the parser's message.
2. **Compile gate (implemented).** When the agent gives a final answer,
   compile (later perhaps `mix format --check-formatted` and
   `mix test --stale`), compare with the baseline, and either finish or
   send the new diagnostics back and continue the turn.
   `Tackle.Elixir.CompileGate` compiles in the project node
   ([`PROJECT_NODE_PLAN.md`](PROJECT_NODE_PLAN.md)), which returns
   diagnostics as data, and takes the baseline before the turn's first
   `edit` or `write` of a project's Elixir source rather than at turn start,
   so turns that change no Elixir code cost nothing. It logs to
   `$TACKLE_HOME/logs/compile_gate.jsonl` and is on by default in the
   harness; see [`packages/tackle_elixir`](../packages/tackle_elixir/README.md).
   Changes made through `bash` are not watched yet.
3. **Lookup tools.** A small allowlist of Tidewave or ElixirLS MCP tools,
   plus a skill that says to use them for macro-generated and dependency
   code.
4. **Review evidence.** A base/head diff of compiler, Credo, and Sobelow
   results, and xref callers of changed functions, fed into
   `Tackle.Review` detectors and verifier.

### Gaps in Tackle

- **Gate seam for plugins (done).** `Tackle.Lib.Hook.before_turn_end/2`
  runs after a final answer when no incoming messages are queued and can
  return `{:continue, messages}` (or `{:continue, messages, context}`) to
  send feedback and continue the turn. Plugins register such hooks like any
  other. The loop bounds repeated continuations only by `max_iterations`;
  a gate counts its own rounds in the context. Hooks also receive the run's
  cancellation signal in their context, so a slow gate can stop early.
- **No per-tool allowlist in `tackle_mcp`.** Needed to expose a few tools
  of a server instead of all of them.
- **Gate decisions are logged to a file (done).** The compile gate appends
  every baseline and check to a JSON-lines log (the TUI hides `Logger`
  output). They are not yet in the session journal or the event stream, so
  the CLI does not show them, and the gate's message appears as an ordinary
  user message.

### Order of work

Build first and use daily, then build the benchmark; but make daily use
produce evidence instead of impressions.

1. **Parse guard and compile gate, with logging from day one.** The
   evidence for gates is the strongest, so building before measuring is low
   risk here. Use them in daily work and read the logs: block rate, repairs
   that pass, valid work blocked.
2. **Collect benchmark cases while working.** Whenever the agent breaks
   something, a gate catches a real error, or a bug is fixed in one of your
   Elixir projects, record the commit, the task, and the check that should
   pass. This grows the case set without a separate mining effort.
3. **Lookup tools only behind a small A/B.** Impressions from daily use are
   unreliable here: tools look useful while the model ignores them or
   re-reads the file anyway. Before adopting them, compare no lookup,
   lookup available, and lookup prompted on 10–20 macro-heavy tasks (Ash,
   Phoenix router, Ecto, protocols). Measure resolution, total tokens, how
   often the tool is chosen, and re-reads after it.
4. **Elixir cases for the review benchmark.** The review already has a
   benchmark (7 cases, 18 seeded bugs; see
   [`code-review-benchmark.md`](code-review-benchmark.md)). Add Elixir
   cases, first from step 2, later from bug-fix commits in public Elixir
   projects (Phoenix, Ecto, Oban, Livebook, Ash), and compare detectors with
   and without analyzer evidence.

## Open questions

- Which checks belong in the gate by default: compile only, or also
  formatting and stale tests? Tests can be slow and flaky.
- How to take a cheap baseline of diagnostics at turn start in large
  projects.
- Whether hub reviews may compile untrusted pull requests in the jail:
  compiling runs macros, which is code execution.
- Whether Tidewave or ElixirLS gives better lookups for agents, and whether
  either needs a running application in practice.
