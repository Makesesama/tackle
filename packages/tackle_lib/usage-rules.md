# Tackle.Lib Usage Rules

Tackle.Lib is a small, **provider-agnostic agent harness** for Elixir: a ReAct-style
loop, a tool-calling contract, system-prompt machinery, and typed lifecycle
hooks. It owns **no persistence, no concrete tools, and no provider SDK** — the
host application supplies those. Keep it that way when working with it.

For the complete capability reference, portability guide, and annotated
ExampleHost host implementation, read [`README.md`](README.md). Phoenix/OTP hosts
should also read [`../tackle_phoenix/README.md`](../tackle_phoenix/README.md).

## Golden rules

- **Never reference host modules from Tackle.Lib.** Tackle.Lib must not mention
  `MyApp.*`/`MyAppWeb.*` in code. Host behaviour is injected
  via config (e.g. `config :tackle_lib, llm: MyApp.AI.TackleAdapter`) or
  passed in at call time. A docstring mention is fine; a code reference is not.
- **The host must configure an LLM adapter** implementing `Tackle.Lib.LLM`. There is
  no default and `Tackle.Lib.LLM.adapter/0` raises without one.
- **`State` is immutable, in-memory, and not persisted.** Tackle.Lib threads it
  through the loop; the host decides how (or whether) to store it.
- **Tools return `{:ok, result} | {:error, reason}`** and never raise for
  control flow — the loop rescues exceptions but that path is for bugs, not
  expected failures.

## Running an agent

```elixir
state =
  Tackle.Lib.new(
    model: "anthropic/claude-sonnet-4",
    tools: Tackle.Lib.Tool.Adapters.Web.wrap([MyApp.Tools.Search, MyApp.Tools.Fetch]),
    system_prompt: MyApp.build_system_prompt(),
    context: %{user_id: user.id}
  )

{:ok, state} = Tackle.Lib.run(state, "How many videos are available?")
Tackle.Lib.last_answer(state)
```

- `Tackle.Lib.new/1` builds `%Tackle.Lib.State{}`. Key opts: `:model`, `:tools`,
  `:system_prompt`, `:context`, `:max_iterations` (default `:infinity`), `:hooks`,
  `:tool_policy`, `:llm_opts`, `:prompt_renderer`, `:id_generator`.
- `Tackle.Lib.run(state, user_input, opts)` runs one turn (think → act → repeat →
  answer). Returns `{:ok, state} | {:error, state} | {:cancelled, state}`.
- `Tackle.Lib.continue(state, opts)` re-runs the loop **without** appending a new
  user message — use it to retry a turn that errored.
- Read results with `Tackle.Lib.last_answer/1`, `Tackle.Lib.messages/1`,
  `Tackle.Lib.usage/1`, `Tackle.Lib.completed?/1`, `Tackle.Lib.error?/1`, `Tackle.Lib.error/1`.

### run/continue options

- `:event_callback` — a 1-arity fn called with `%Tackle.Lib.Event{}` structs (run
  lifecycle, message start/end, tool start/end, usage). Use this for streaming
  UI, logging, and metrics rather than inspecting state mid-run.
- `:llm_stream` — when `true`, uses the adapter's `stream/3` if implemented,
  falling back to `generate/2`.
- `:cancellation_signal` — a `Tackle.Lib.Cancellation.Signal` checked between loop
  steps and passed into tool context; adapters/tools should observe it and abort.

## Defining tools

Prefer the DSL via `use Tackle.Lib.Tool`:

```elixir
defmodule MyApp.Tools.Search do
  use Tackle.Lib.Tool

  tool_name "search"
  description "Search indexed documents."

  input do
    field :query, :string, required: true
    field :limit, :integer, default: 10
  end

  output do
    field :results, {:list, :map}, required: true
  end

  def run(%{"query" => query, "limit" => limit}, ctx) do
    MyApp.Search.run(query, limit, ctx)
  end
end
```

- `use Tackle.Lib.Tool` generates the behaviour callbacks (`name/0`,
  `description/0`, `parameters_schema/0`, `output_schema/0`, `execute/2`) from
  the DSL. You define `run/2`.
- **Arguments arrive as a map with string keys** (`%{"query" => ...}`) —
  validated and coerced against the input schema before `run/2` is called.
- `field` types: `:string`, `:integer`, `:float`, `:boolean`, `:map`,
  `{:list, inner}`. Options: `required: true`, `default: value`,
  `description: "..."`.
- The second `run/2` argument is the **host-supplied context map** (`:context`
  from `Tackle.Lib.new/1`), carrying things like `user_id`, permissions, and (when
  cancellable) `:cancellation_signal`. Tackle.Lib never populates domain data here.
- An `output do ... end` block is optional; when present, results are validated
  against it before being projected into the transcript.
- To adapt a richer existing tool abstraction, implement the `Tackle.Lib.Tool`
  callbacks manually instead of using the DSL — the loop only sees the behaviour.
- Wrap tool lists with `Tackle.Lib.Tool.Adapters.Web.wrap/1` before passing to
  `Tackle.Lib.new/1`; it validates each module exports the required callbacks.

## The LLM adapter (host-supplied)

The host implements `Tackle.Lib.LLM` and wires it up:

```elixir
config :tackle_lib, llm: MyApp.AI.TackleAdapter
```

- Required callback: `generate(schema, opts) :: {:ok, response} | {:error, term}`.
- Optional callbacks: `stream(schema, opts, event_callback)` for streaming and
  `model_info(model)` for adapter-owned context/output limits and price cards.
- `opts[:messages]` is the **sole conversation transport**: a provider-neutral,
  role-tagged array (`Tackle.Lib.Messages.to_provider/1`) with `:user`, `:assistant`
  (carrying native `:tool_calls`), and `:tool` entries linked by `:tool_call_id`.
  Send this array to the provider as-is — **do not flatten history**.
- Tackle.Lib also sets `:model`, `:system`, `:temperature`, `:strict_schema`,
  `:native_tools`, `:tools`, and appends host `:llm_opts`.
- Return `{:ok, %{data: map, usage: map | %Tackle.Lib.Usage{} | nil, model: binary | nil}}`.
  `:data` holds assistant `content` and/or native `tool_calls`. Tackle.Lib
  normalizes `:usage` into `%Tackle.Lib.Usage{}` and applies the selected
  adapter's price card when provider cost is absent. Derived cost is estimated;
  host billing and quota policy remain host-owned.
- `schema` is an optional structured-response schema for **non-tool** turns;
  tool calls always flow through provider-native `tool_calls`, not the schema.

## Lifecycle hooks

Implement `Tackle.Lib.Hook` to observe/mutate the loop without touching it. All
callbacks are optional; implement only what you need. Order per turn:
`before_prompt/2` → `after_prompt/3` → `before_tool_call/3` →
`after_tool_call/3` → `after_message/3` → `after_turn/2`.

Return conventions:

- `:ok` — observer only.
- `{:ok, context}` — mutator; the returned map replaces the run context for
  later steps.
- `{:error, reason}` — abort the turn with that error.

```elixir
defmodule MyApp.Hooks.AuditLogger do
  @behaviour Tackle.Lib.Hook

  @impl true
  def after_turn(state, _context) do
    MyApp.Audit.log(:agent_turn, state.session_id, state.status)
    :ok
  end
end

Tackle.Lib.new(hooks: [MyApp.Hooks.AuditLogger], context: %{user_id: user.id})
```

Use hooks (not loop edits) for auditing, persistence, metrics, and per-call
argument enrichment. Persist messages in `after_message/3`; do teardown in
`after_turn/2`.

## System prompts

- The host composes `state.system_prompt` — Tackle.Lib uses it as-is.
- `Tackle.Lib.SystemPrompt` provides composable builders (`new/0`, `add_section/3`,
  `add_raw/2`) plus tool-doc assembly. Tool execution uses provider-native tool
  calls, not prompt-level JSON envelopes.
- A `Tackle.Lib.PromptRenderer` module (host-owned) aligns tool descriptions and any
  structured-response schema per surface.

## Integrations

- `Tackle.Lib.Integrations.Anubis` exposes `Tackle.Lib.Tool` modules through Anubis MCP.
  It owns no server setup, auth, or tenant scope — the host Anubis server
  resolves/authorizes the request and passes a context builder to `dispatch/4`.
  Requires the optional `:anubis_mcp` dep.

## Things to avoid

- Don't add a default model, default tools, or a bundled provider SDK to Tackle.Lib.
- Don't persist state inside Tackle.Lib or reach for a database — that's the host's job.
- Don't bypass the tool contract by calling `execute/2` directly from the loop;
  go through `Tackle.Lib.Tool.settle/3` (the loop already does).
- Don't hand the adapter a flattened string transcript — always the structured
  `opts[:messages]` array.
- Don't raise from a tool's `run/2` for expected failures; return
  `{:error, reason}`.
