# Handoff: Session token, cost, and context tracking

## Goal

Build provider-neutral session statistics into the Tackle harness:

- track uncached input, output, reasoning, cache-read, and cache-write tokens;
- track itemized and total monetary cost;
- expose each selected model's context window and maximum output tokens;
- calculate current context pressure similarly to Pi so later compaction policy has reliable input;
- project totals and current context pressure through harness session snapshots/events; and
- show concise statistics in the CLI footer.

Do **not** implement automatic compaction in this task. This work should expose deterministic data that a later compaction policy can consume.

## Architecture decisions

- `Tackle.Lib` remains provider-neutral and owns normalized value types/calculations.
- Adapters own model limits and price cards because these vary by provider.
- Add an optional `model_info/1` callback to `Tackle.Lib.LLM`; do not make it required for third-party adapters.
- Provider-reported cost is authoritative when present. Price-card-derived cost must be marked as estimated.
- Session totals continue to be derived from assistant-message usage so a second mutable counter cannot drift.
- Current context usage is **not** cumulative session input. It uses the latest valid assistant usage checkpoint plus an estimate for messages added after that checkpoint.
- No new dependencies are needed.

## Existing foundation

Before this task, `Tackle.Lib.Usage` already normalized and aggregated:

- `input_tokens` (uncached input),
- `output_tokens`,
- `reasoning_tokens`,
- `cache_read_tokens`,
- `cache_write_tokens`,
- `total_tokens`,
- optional `cost`/`currency`, and
- model/provider/raw metadata.

`Tackle.Lib.Usage.prompt_tokens/1` and `cache_hit_rate/1` already use disjoint input/cache buckets. `Tackle.Lib.State.usage/1` derives aggregate usage from assistant messages. The CLI currently retains only the latest usage and displays a `CH<n.n>%` cache-hit indicator.

## Partial implementation currently in the working tree

### `packages/tackle_lib/lib/tackle_lib/model_info.ex` (new)

Introduces `%Tackle.Lib.ModelInfo{}` with:

- `model`,
- `context_window`,
- `max_output_tokens`, and
- pricing rates for input/output/cache read/cache write, currency, and rate unit.

It includes metadata validation and `estimate_cost/2`, which computes itemized costs and marks derived totals with `cost_estimated: true`.

### `packages/tackle_lib/lib/tackle_lib/context_usage.ex` (new)

Introduces `%Tackle.Lib.ContextUsage{}` with:

- `tokens`,
- `context_window`,
- `percent`,
- `remaining_tokens`,
- `usage_tokens`,
- `trailing_tokens`, and
- `estimated?`.

It finds the latest assistant usage checkpoint and estimates later message content at four characters per token. With no checkpoint, it estimates the system prompt, messages, and tools.

### `packages/tackle_lib/lib/tackle_lib/usage.ex` (modified)

Adds:

- `cost_breakdown`,
- `cost_estimated`,
- normalization/aggregation for those fields, and
- `context_tokens/1`.

## Important: partial code has not been validated

No compile, formatting, or test command has been run since these edits. Treat all three files above as a draft that needs review.

Known issues/questions to resolve before wiring it in:

1. `ContextUsage.estimate/1` currently matches `state.llm.model_info`, but `%Tackle.Lib.LLM.Selection{}` does not yet have that field. Add it to the selection struct or change the lookup flow.
2. Decide whether `Usage.context_tokens/1` should use provider `total_tokens` (Pi does) or prompt-only tokens for compaction pressure. Pi's current implementation uses `totalTokens || input + output + cacheRead + cacheWrite`; the draft follows that behavior.
3. The initial-context estimator uses `inspect(state.tools)`. A better implementation may estimate frozen provider-neutral tool definitions and the effective prompt sent to the adapter.
4. `cost_breakdown` should probably have a documented typed shape rather than generic `map()`.
5. Review aggregate estimated-cost semantics when authoritative and estimated entries are mixed. Current behavior sums compatible numeric costs but only sets aggregate `cost_estimated: true` when every cost is estimated.
6. Handle provider aliases/versioned response model names carefully: pricing should use the requested adapter-local catalog model unless an adapter deliberately resolves a returned model to another known price card.
7. Context remaining may need a separate value after reserving output tokens. Preserve raw remaining context and expose an output reservation explicitly rather than silently conflating the two.

## Remaining implementation plan

### 1. Complete the optional adapter metadata contract

Update `packages/tackle_lib/lib/tackle_lib/llm.ex`:

```elixir
@callback model_info(model :: String.t()) :: Tackle.Lib.ModelInfo.t() | map() | nil
@optional_callbacks adapter_id: 0, models: 0, model_info: 1, stream: 3
```

Add a safe public helper that:

- returns `{:ok, nil}` when the callback is absent;
- calls and validates `model_info/1` when present; and
- returns explicit callback/validation errors rather than silently accepting malformed metadata.

Update `packages/tackle_lib/lib/tackle_lib/llm/selection.ex` to resolve metadata once and store it on `%Selection{}`. Add `model_info` to the struct/type. This makes model limits stable and naturally carries them through state and per-turn snapshots. Update selection tests for adapters with metadata, adapters without it, invalid metadata, and callback failure.

This extends the public adapter API non-breakingly because the callback is optional.

### 2. Apply adapter pricing to every normalized response

Choose one clear ownership point. Recommended:

- `Tackle.Lib.LLM.normalize_response/2` accepts the adapter/requested model context;
- usage is normalized first;
- selected model metadata is used to estimate cost only if the provider did not return authoritative numeric cost; and
- itemized estimates may still be attached when authoritative total cost exists.

Alternatively, Codex can price its own usage before returning it. Whichever approach is chosen, keep provider facts in the adapter and generic arithmetic in `ModelInfo`.

Streaming usage events need the priced usage too. The Codex SSE parser currently emits raw normalized usage before `LLM` receives the final response, so either:

- decorate usage events in `LLM.stream_with/4`, or
- price in the Codex adapter/SSE layer before emitting.

Avoid having live footer cost differ from settled-message cost.

### 3. Add Codex model metadata

Implement `model_info/1` in:

`plugins/tackle_codex/lib/tackle/plugins/codex.ex`

The local Pi checkout was inspected as a reference. Its catalog currently declares:

| Model | Context | Max output | USD per 1M: input / output / cache read / cache write |
| --- | ---: | ---: | --- |
| `gpt-5.3-codex-spark` | 128,000 | 128,000 | 1.75 / 14 / 0.175 / 0 |
| `gpt-5.4` | 272,000 | 128,000 | 2.5 / 15 / 0.25 / 0 |
| `gpt-5.4-mini` | 272,000 | 128,000 | 0.75 / 4.5 / 0.075 / 0 |
| `gpt-5.5` | 272,000 | 128,000 | 5 / 30 / 0.5 / 0 |
| `gpt-5.6-luna` | 272,000 | 128,000 | 0.2 / 1.2 / 0.02 / 0.25 |
| `gpt-5.6-sol` | 272,000 | 128,000 | 5 / 30 / 0.5 / 6.25 |
| `gpt-5.6-terra` | 272,000 | 128,000 | 2 / 12 / 0.2 / 2.5 |
| `gpt-6-astra` | 272,000 | 128,000 | 10 / 50 / 1 / 12.5 |

Pi also models higher long-context rates above 272,000 input tokens. These Codex context windows are capped at 272,000, so those tiers should not normally apply here. Confirm price-card freshness and document that derived costs are estimates. ChatGPT subscription usage may not correspond to an actually billed API charge, so the UI must not imply an authoritative invoice.

Add Codex tests for metadata and itemized usage cost, including cache tokens.

### 4. Finish context pressure APIs

Review and test `Tackle.Lib.ContextUsage`.

Recommended public APIs:

```elixir
Tackle.Lib.context_usage(state)
Tackle.Lib.ContextUsage.estimate(state, model_info)
```

Behavior to cover:

- no model metadata returns `nil`;
- latest valid assistant usage is the checkpoint;
- all-zero usage is ignored;
- trailing user/tool messages add estimated tokens;
- context percentage may exceed 100%;
- remaining tokens clamps at zero;
- model reconfiguration uses the new model's context window while retaining conversation;
- no provider checkpoint returns a clearly marked estimate; and
- cache-read/write buckets are included exactly once.

If output reservation is included, expose fields such as `reserved_output_tokens` and `available_input_tokens`. Do not reserve the full 128k output maximum by default without checking Pi's actual compaction policy; its compaction uses a configurable reserve threshold.

### 5. Project statistics through harness snapshots

Update `lib/tackle/session.ex` and tests. A session snapshot should expose, directly or through a dedicated stats struct:

- aggregate session usage (`State.usage/1`),
- latest generation usage,
- model metadata,
- current context usage/pressure.

Prefer a dedicated immutable value such as `%Tackle.Session.Stats{}` over many unrelated snapshot fields. Compute it from `agent_state`; do not maintain duplicate mutable totals in the GenServer.

Usage events already flow through:

```elixir
{:tackle_event, session_id, turn_id, %Tackle.Lib.Event{type: :usage}}
```

If context pressure is attached to usage events, keep it provider-neutral and ensure the terminal settled snapshot agrees with the event projection.

### 6. Update CLI footer

Update `frontends/tackle_cli/lib/tackle_cli/tui.ex` and its tests. Replace the cache-only prefix with compact session stats, for example:

```text
ctx 84k/272k (30.9%) · in 126k · out 8k · CH71.0% · ~$0.84
```

Guidance:

- `ctx` uses current context usage, not cumulative input;
- `in`/`out` and cost use aggregate session usage;
- display `~$` (or another explicit marker) for estimated cost;
- retain `CH` only when cache reporting exists/activity has occurred;
- omit unavailable values instead of displaying misleading zeroes;
- format large token counts compactly and deterministically;
- account for narrow terminal width (possibly prioritize context, then cost/cache, then controls).

Current test to extend:

`frontends/tackle_cli/test/tackle_cli/tui_test.exs`

It already checks the Pi-compatible cache rate and can be expanded to verify context, aggregate input/output, cost, estimated marker, unavailable metadata, and updates after model reconfiguration.

### 7. Documentation

Update:

- root `README.md`;
- `packages/tackle_lib/README.md`;
- `plugins/tackle_codex/README.md`; and
- `frontends/tackle_cli/README.md`.

Document callback shape, disjoint token buckets, context calculation, estimate semantics, price ownership, and that automatic compaction remains future work.

## Relevant source files

- `packages/tackle_lib/lib/tackle_lib/usage.ex`
- `packages/tackle_lib/lib/tackle_lib/model_info.ex` (new draft)
- `packages/tackle_lib/lib/tackle_lib/context_usage.ex` (new draft)
- `packages/tackle_lib/lib/tackle_lib/llm.ex`
- `packages/tackle_lib/lib/tackle_lib/llm/selection.ex`
- `packages/tackle_lib/lib/tackle_lib/state.ex`
- `packages/tackle_lib/lib/tackle_lib/message.ex`
- `packages/tackle_lib/lib/tackle_lib/loop.ex`
- `packages/tackle_lib/lib/tackle_lib/snapshot.ex`
- `lib/tackle/session.ex`
- `plugins/tackle_codex/lib/tackle/plugins/codex.ex`
- `plugins/tackle_codex/lib/tackle/plugins/codex/sse.ex`
- `frontends/tackle_cli/lib/tackle_cli/tui.ex`

## Suggested focused tests

- `packages/tackle_lib/test/tackle_lib/model_info_test.exs` (new)
- `packages/tackle_lib/test/tackle_lib/context_usage_test.exs` (new)
- `packages/tackle_lib/test/tackle_lib/usage_test.exs`
- `packages/tackle_lib/test/tackle_lib/llm_test.exs`
- `packages/tackle_lib/test/tackle_lib/state_test.exs`
- `test/tackle_test.exs`
- `plugins/tackle_codex/test/codex_test.exs`
- `frontends/tackle_cli/test/tackle_cli/tui_test.exs`

Because `Tackle.Lib.Usage` is consumed by the Phoenix package, run Phoenix checks too after the library struct changes.

## Validation commands

From repository root:

```sh
(cd packages/tackle_lib && mix format 'lib/tackle_lib/{usage,model_info,context_usage,llm,state}.ex' 'lib/tackle_lib/llm/selection.ex' 'test/tackle_lib/{usage,model_info,context_usage,llm,state}_test.exs')
(cd packages/tackle_lib && mix compile --warnings-as-errors && mix test)

mix format 'lib/tackle/session.ex' 'test/tackle_test.exs'
mix compile --warnings-as-errors && mix test

(cd packages/tackle_phoenix && mix compile --warnings-as-errors && mix test)

(cd plugins/tackle_codex && mix format 'lib/tackle/plugins/codex.ex' 'lib/tackle/plugins/codex/sse.ex' 'test/codex_test.exs')
(cd plugins/tackle_codex && mix compile --warnings-as-errors && mix test)

(cd frontends/tackle_cli && mix format 'lib/tackle_cli/tui.ex' 'test/tackle_cli/tui_test.exs')
(cd frontends/tackle_cli && mix compile --warnings-as-errors && mix test)

git diff --check
git status --short
git diff
```

Use `nix develop` if the configured Elixir 1.20 / OTP 29 toolchain is not already active.

## Working-tree caution

At handoff time, the intended source changes are only:

- modified `packages/tackle_lib/lib/tackle_lib/usage.ex`;
- untracked `packages/tackle_lib/lib/tackle_lib/model_info.ex`; and
- untracked `packages/tackle_lib/lib/tackle_lib/context_usage.ex`.

The repository also has unrelated untracked paths (`.nix-hex/`, `.nix-mix/`, `.pi/`, `credo-debug-log.html`, `repos/`, and `todos.md`). Preserve them and do not clean or commit them as part of this work.
