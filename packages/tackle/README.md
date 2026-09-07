# Tackle

Tackle is a small, provider-agnostic agent harness for Elixir. It provides the
framework-free core of a tool-using LLM agent and leaves provider access,
persistence, authorization, billing, concrete tools, and UI to the host
application.

This document has two goals:

1. describe the complete Tackle surface and its limits; and
2. explain how ExampleHost hosts Tackle so the same design can be reused in
   another application.

For an OTP/Phoenix runtime with supervised turns, PubSub, and LiveView stream
support, also read [`../tackle_phoenix/README.md`](../tackle_phoenix/README.md).

## Status and installation

Tackle currently lives as an in-repo Mix package. It is not published to Hex and
the repository root is a different Mix project. To use it in another project
today, either:

- copy/extract `packages/tackle` into that project and use a path dependency; or
- extract the package to its own Git repository, then use a normal Git dependency.

For a copied package under `packages/tackle`:

```elixir
# mix.exs
defp deps do
  [
    {:tackle, path: "packages/tackle"}
  ]
end
```

Tackle requires Elixir `~> 1.18`. The Anubis MCP bridge requires the optional
`:anubis_mcp` dependency to be available in the final application. Tackle emits
`:telemetry` events; a Phoenix application already has `:telemetry`, while a
non-Phoenix host must make sure it is present in the final dependency graph.

## Which package do I need?

| Use case | Package |
|---|---|
| CLI command, Oban job, test, or one synchronous turn | `tackle` |
| Your application already owns processes and persistence | `tackle` |
| Supervised background turns with cancellation and PubSub | `tackle` + `tackle_phoenix` |
| Incrementally rendered LiveView chat | `tackle` + `tackle_phoenix` |
| Expose the same tools through Anubis MCP | `tackle` with optional `:anubis_mcp` |

## Architecture

```text
host application
  ├── LLM/provider adapter ─────────────── implements Tackle.LLM
  ├── concrete domain tools ───────────── implements Tackle.Tool
  ├── prompt and prompt renderer ──────── implements Tackle.PromptRenderer (optional)
  ├── persistence/auth/billing/UI ─────── host-owned
  │
  └── Tackle
      ├── State + Message + Usage
      ├── per-turn Snapshot
      ├── Loop
      │   ├── structured provider messages
      │   ├── native tool calls
      │   ├── hooks and events
      │   └── cooperative cancellation
      ├── provider-neutral tool schemas
      └── optional Anubis MCP bridge
```

The central boundary is intentional: Tackle knows **how** to run an agent turn,
but not which provider, user, tenant, database, or business policy is involved.

## Five-minute core example

### 1. Implement an LLM adapter

```elixir
defmodule MyApp.AI.TackleAdapter do
  @behaviour Tackle.LLM

  @impl true
  def generate(_schema, opts) do
    # Translate these provider-neutral values to your provider SDK/client:
    model = Keyword.fetch!(opts, :model)
    system = Keyword.get(opts, :system)
    messages = Keyword.fetch!(opts, :messages)
    tools = Keyword.get(opts, :tools, [])

    with {:ok, response} <- MyApp.AI.chat(model, system, messages, tools) do
      {:ok,
       %{
         data: %{
           "content" => response.content,
           "tool_calls" => response.tool_calls
         },
         usage: response.usage,
         model: response.model,
         provider: response.provider
       }}
    end
  end
end
```

Configure it under Tackle's own OTP application key:

```elixir
# config/config.exs
config :tackle, llm: MyApp.AI.TackleAdapter
```

There is deliberately no default adapter.

### 2. Define a tool

```elixir
defmodule MyApp.Agent.Tools.SearchDocuments do
  use Tackle.Tool

  tool_name "search_documents"
  description "Search documents visible to the current tenant."

  input do
    field :query, :string, required: true
    field :limit, :integer, default: 10
  end

  output do
    field :results, {:list, :map}, required: true
  end

  def run(%{"query" => query, "limit" => limit}, context) do
    MyApp.Search.search(query,
      limit: limit,
      scope: Map.fetch!(context, :scope)
    )
  end
end
```

Tool arguments are normalized to **string keys** before `run/2`. A tool returns
`{:ok, result}` or `{:error, reason}`. Expected failures should not raise. At a
public agent boundary, `Tackle.Tool.Adapters.Web.wrap/1` can validate the tool
modules before they are placed in state.

### 3. Compose a prompt and run the agent

```elixir
tools = [MyApp.Agent.Tools.SearchDocuments]

authoring_prompt =
  Tackle.SystemPrompt.new()
  |> Tackle.SystemPrompt.add_section("Role", "You answer from verified documents.")
  |> Tackle.SystemPrompt.add_tools(tools)
  |> Tackle.SystemPrompt.add_response_format()
  |> Tackle.SystemPrompt.to_string()

state =
  Tackle.new(
    model: "provider/model-name",
    tools: tools,
    system_prompt: authoring_prompt,
    context: %{scope: current_scope},
    max_iterations: 10
  )

case Tackle.run(state, "What changed this week?") do
  {:ok, final_state} ->
    IO.puts(Tackle.last_answer(final_state))

  {:error, failed_state} ->
    IO.warn(Tackle.error(failed_state))

  {:cancelled, cancelled_state} ->
    IO.warn(cancelled_state.error)
end
```

`Tackle.run/3` is synchronous. A host that needs a long-lived or cancellable UI
turn should run it in a supervised process; `tackle_phoenix` provides that
runtime.

## What is possible with Tackle?

Tackle can be used to build:

- multi-step ReAct agents that call zero or more native provider tools;
- single-turn assistants with no tools;
- CLI, background-job, API, and Phoenix/LiveView agents;
- streaming UIs using provider-independent lifecycle events;
- tenant-aware tools by passing a host authorization object in `state.context`;
- durable conversations by mapping `Tackle.Message` to host storage;
- quota and billing systems using normalized per-step `Tackle.Usage`;
- audit and persistence extensions through lifecycle hooks;
- provider-switchable agents through the `Tackle.LLM` behaviour;
- prompt variants through `Tackle.PromptRenderer`;
- tools reused by an agent and an MCP server through the Anubis integration;
- parent/child or other orchestration models implemented by host tools and
  persistence; and
- deterministic tests through injected ID generators and fake LLM adapters.

ExampleHost uses all of the important seams: OpenRouter is behind an adapter,
domain tools receive organization-aware permission context, Ecto persists
messages, subscriptions gate and bill turns, Phoenix streams events to the UI,
and selected tools are also exposed through MCP.

## Public API

### Building and running state

```elixir
state = Tackle.new(opts)
Tackle.run(state, user_input, run_opts)
Tackle.continue(state, run_opts)
```

`Tackle.new/1` accepts:

| Option | Purpose | Default |
|---|---|---|
| `:model` | Host/provider model identifier | `nil` |
| `:tools` | Modules implementing `Tackle.Tool` | `[]` |
| `:system_prompt` | Complete host-composed system prompt | `nil` |
| `:context` | Opaque host context passed to hooks and tools | `%{}` |
| `:max_iterations` | Maximum LLM/tool loop iterations | `10` |
| `:hooks` | Modules implementing `Tackle.Hook` | `[]` |
| `:tool_policy` | Tool execution policy | sequential default |
| `:llm_opts` | Additional adapter options | `[]` |
| `:prompt_renderer` | Prompt renderer module | configured/default renderer |
| `:prompt_renderer_opts` | Renderer options | `[]` |
| `:id_generator` | Zero-arity session/message/tool-call ID function | UUID generator |

`Tackle.run/3` appends one user message. `Tackle.continue/2` does **not** append a
message; it clears the error/status, resets the iteration budget, and retries
the existing conversation. This is the correct primitive for a Retry button
after the user's message has already been recorded.

Run options:

| Option | Purpose |
|---|---|
| `:event_callback` | Receives `%Tackle.Event{}` values |
| `:llm_stream` | Uses adapter `stream/3`, with generate fallback |
| `:cancellation_signal` | Cooperative cancellation handle |

Results are always one of:

```elixir
{:ok, %Tackle.State{status: :completed}}
{:error, %Tackle.State{status: :error}}
{:cancelled, %Tackle.State{status: :cancelled}}
```

Convenience readers are `Tackle.last_answer/1`, `Tackle.messages/1`,
`Tackle.usage/1`, `Tackle.completed?/1`, `Tackle.error?/1`, and
`Tackle.error/1`.

### Turn lifecycle

A normal tool-using turn is:

```text
capture immutable snapshot
emit turn_start
append + finalize user message
repeat until final answer or max_iterations:
  set thinking; emit message_start + step_start
  before_prompt hook
  call or stream LLM
  after_prompt hook
  ├── final content:
  │     append assistant message; emit message_end, status_change, turn_end
  └── native tool calls:
        append assistant tool-call message
        for each call, in provider order:
          before_tool_call hook
          validate input
          execute tool
          validate/project output
          append linked tool-result message
          after_tool_call hook
        repeat
run after_turn hook
clear per-turn snapshot
```

The message history sent to an adapter is structured, not flattened. Assistant
tool calls and tool results remain linked by `tool_call_id`, which is required
by modern chat-completion APIs and enables provider prompt caching.

## LLM adapter contract

Implement `Tackle.LLM`:

```elixir
@callback generate(schema :: keyword() | map() | nil, opts :: keyword()) ::
            {:ok, response} | {:error, term()}

@callback stream(schema, opts, event_callback) ::
            {:ok, response} | {:error, term()}
```

`stream/3` is optional. When absent, Tackle calls `generate/2` and still emits a
normalized usage event when usage is returned.

The loop supplies these adapter options:

- `:model`
- `:system`
- `:messages` — the sole conversation transport
- `:temperature`
- `:strict_schema`
- `:native_tools`
- `:tools` — provider-neutral definitions
- `:cancellation_signal`, when present
- host `state.llm_opts`, except unsupported tool-policy options

A provider-neutral message array looks like:

```elixir
[
  %{role: :user, content: "Find the document"},
  %{
    role: :assistant,
    content: nil,
    tool_calls: [
      %{
        id: "call-1",
        type: "function",
        function: %{name: "search_documents", arguments: "{\"query\":\"...\"}"}
      }
    ]
  },
  %{
    role: :tool,
    tool_call_id: "call-1",
    name: "search_documents",
    content: "{\"results\":[...]}"
  },
  %{role: :user, content: "Use the tool results to answer."}
]
```

The adapter returns:

```elixir
{:ok,
 %{
   data: %{"content" => "...", "tool_calls" => []},
   usage: %{
     input_tokens: 100,
     output_tokens: 20,
     cache_read_tokens: 80,
     cost: 0.002,
     currency: "USD"
   },
   model: "provider/model-name",
   provider: "provider"
 }}
```

`:usage` may already be `%Tackle.Usage{}`, a string- or atom-keyed provider map,
or `nil`. Tackle normalizes it. Pricing remains host-owned.

Provider adapters are also responsible for translating Tackle's normalized
tool definitions into the provider wire format. `opts[:tools]` contains
serializable `:input_schema` field maps. In code that still has a tool module's
native keyword schema, `Tackle.Tool.Schema.JsonSchema.to_json_schema/1` provides
the standard JSON Schema projection.

## Tool system

### Behaviour and DSL

A manual tool implements:

- `name/0`
- `description/0`
- `parameters_schema/0`
- `execute/2`
- optional `output_schema/0`
- optional `description_metadata/0`

`use Tackle.Tool` generates the standard callbacks from the DSL and delegates
execution to `run/2`.

Supported schema types are:

- `:string`
- `:integer`
- `:float`
- `:boolean`
- `:map`
- `{:list, inner_type}`
- `{:array, inner_type}`

Field options include `:required`, `:default`, `:description`, and `:enum`.
Integer, float, and boolean strings are coerced where unambiguous. Empty values
are treated as absent. Tackle never creates atoms from provider/user keys.

### Settlement and errors

`Tackle.Tool.settle/3` is the canonical local execution pipeline:

1. normalize and validate arguments;
2. execute the host tool;
3. validate output when a schema exists;
4. preserve the raw result for host events;
5. project the result to text/JSON for the model transcript.

Do not bypass settlement in custom runtimes. It is what keeps agent and MCP
execution consistent.

Expected tool failures return `{:error, reason}`. Tackle converts them into a
linked tool result with sanitized model-facing content while detailed failure
information remains available in `:tool_error` events. Exceptions are rescued
and logged as bugs; they should not be normal control flow.

Unknown tools and stale `definition_id` values settle as typed errors rather
than executing a different definition. Tool names must be unique in a registry.
Definitions and tool sets have deterministic SHA-256-derived IDs for audit and
cache keys.

### Tool policy

Tool calls currently execute **sequentially in the exact order requested by the
model**. Tackle intentionally does not support forced tool choice, provider-side
parallel tool calls, allow/deny options, or weighting. These keys are removed
from `llm_opts`:

- `:tool_choice`
- `:parallel_tool_calls`
- `:allowed_tools`
- `:disallowed_tools`
- `:tool_weights`
- `:tool_policy`

Select allowed tools before the turn by constructing a tenant/user-scoped tool
list. Do not rely on provider options as the authorization boundary.

## Context and authorization

`Tackle.State.context` is an opaque host map. Tackle passes it through hooks and
to every tool. If a cancellation signal exists, the tool receives it under
`:cancellation_signal` as well.

A useful host context shape is:

```elixir
%{
  scope: current_scope,
  permissions: permission_context,
  tenant_id: tenant.id,
  actor_id: user.id,
  metadata: %{request_id: request_id}
}
```

Tackle does not authorize this data. The host must derive trusted context from
the authenticated request or persisted session, and every data-holding tool
must enforce the tenant boundary itself. ExampleHost reconstructs authorization
from the persisted user and organization before every durable turn rather than
trusting browser-supplied IDs.

## Hooks

Implement `Tackle.Hook` to observe or mutate context at stable lifecycle points:

| Callback | Called |
|---|---|
| `before_prompt/2` | Before each LLM request |
| `after_prompt/3` | After parsing the LLM response |
| `before_tool_call/3` | Before each normalized tool call |
| `after_tool_call/3` | After each success/error settlement |
| `after_message/3` | After each finalized user/assistant/tool message |
| `after_turn/2` | Once during terminal cleanup |

Return `:ok` to observe, `{:ok, new_context}` to replace the context for later
steps, or `{:error, reason}` to abort the turn. Hooks run in configured order;
each receives the context returned by the previous hook.

Good hook uses include audit logging, incremental persistence, correlation
metadata, and cleanup. ExampleHost uses `after_message/3` and `after_turn/2` for
idempotent message persistence and title generation.

Do not use hooks as a substitute for tool authorization. A hook can abort a
turn, but the tool remains the final security boundary for its operation.

## Events and streaming

Pass `event_callback: fn event -> ... end` to receive provider-independent
events. Event types include:

- `:turn_start`, `:turn_end`, `:turn_cancelled`
- `:step_start`, `:step_end`
- `:message_start`, `:message_delta`, `:message_end`
- `:tool_start`, `:tool_end`, `:tool_error`
- `:usage`, `:status_change`, `:error`
- `:provider_event` for unrecognized provider data

Every event is `%Tackle.Event{type, id, parent_id, data, timestamp, metadata}`.
Streaming text, reasoning, tool-input, usage, and provider errors are normalized
through `Tackle.Event.normalize/2`. The loop stamps streamed message deltas with
the message ID minted at `:message_start`, allowing a UI to route concurrent
in-flight display state safely.

Reasoning and tool-input deltas are tagged in event data. A user-facing UI
should not append them to the visible answer bubble by default. The
`tackle_phoenix` event reducer follows this rule.

Event callbacks should be fast. Send events to another process or PubSub rather
than doing slow database work in the callback; use hooks or the Phoenix Store
settlement seam for durable work.

## Cooperative cancellation

```elixir
signal = Tackle.Cancellation.new_signal()

Task.start(fn ->
  Tackle.run(state, input,
    cancellation_signal: signal,
    llm_stream: true
  )
end)

Tackle.Cancellation.cancel(signal, :user_cancelled)
```

The loop checks cancellation before work, after LLM calls, and between tool
calls. The adapter receives the signal in its opts and tools receive it in
context. Long-running adapters and tools should check
`Tackle.Cancellation.cancelled?/1` and abort their own work.

Cancellation is cooperative, not preemptive. Tackle cannot interrupt code that
ignores the signal. Delete signals after terminal settlement with
`Tackle.Cancellation.delete/1`; `Tackle.Phoenix.Runner` manages this lifecycle
automatically.

The cancellation store is configurable:

```elixir
config :tackle, cancellation_store: MyApp.CancellationStore
```

It defaults to an ETS-backed implementation that supports cross-process access
on one BEAM node.

## Prompts and structured non-tool responses

The host owns the domain prompt. `Tackle.SystemPrompt` only provides composable
structure:

- `new/0`
- `add_section/3`
- `add_raw/2`
- `add_tools/3`
- `add_response_format/2`
- `to_string/1`
- `version_id/1`

`Tackle.PromptRenderer` controls how tools and response guidance are rendered and
may return a response schema for a structured **non-tool** turn. Tool execution
always uses provider-native tool calls. The built-in
`Tackle.PromptRenderer.NativeTools` is the default.

A host may implement `description_metadata/0` on tools and render the same
structured documentation differently for web prompts and MCP. ExampleHost renders
Markdown for its web agent and XML-oriented descriptions for MCP while sharing
the same tool modules.

The short trailing instruction used on each loop step can be configured as one
string, a keyword/map with `:without_tool_results` and `:with_tool_results`, or a
one-argument function:

```elixir
config :tackle,
  instruction: [
    without_tool_results: "Call a tool if more facts are needed; otherwise answer.",
    with_tool_results: "Answer from the results or call another tool if incomplete."
  ]
```

## Snapshots and configuration stability

At the start of a turn Tackle captures `%Tackle.Snapshot{}` containing the
resolved adapter, model, tools/registry, hooks, prompt, prompt renderer, and LLM
options. That turn continues against the frozen snapshot even if application
configuration or code registration changes while it runs.

Snapshots include deterministic `system_prompt_version_id` and
`tools_version_id` values. Persist those IDs in host audit records when you need
to explain which configuration a turn used. The snapshot itself is cleared from
state during terminal cleanup.

## Prompt caching

`Tackle.Cache` adds provider-compatible cache-control markers to the stable
request prefix:

```elixir
Tackle.new(llm_opts: [cache: true])
```

Adapters opt in by calling:

```elixir
control = Tackle.Cache.control(opts)
messages = Tackle.Cache.mark_system(messages, control)
tools = Tackle.Cache.mark_last_tool(tools, control)
```

This only marks cache breakpoints; it does not store or evict cached content.
Providers that ignore the marker are unaffected. ExampleHost enables this by
default for its web agent.

## Usage and billing

Each assistant generation may carry `%Tackle.Usage{}` with input, output,
reasoning, cache-read, cache-write, total tokens, optional cost/currency, model,
provider, and raw provider metadata.

`Tackle.usage(state)` derives aggregate usage from assistant messages so a
separate mutable total cannot drift. Cost aggregation is conservative: costs
are summed only when every entry has numeric cost and currencies are compatible.

Tackle does not know price cards, subscriptions, credits, or tenants. Compute
cost in the adapter or host settlement layer and enforce quota **before** a turn
starts. `Tackle.Phoenix.Store.before_turn/2` and `settle_turn/4` are designed for
that split.

## Telemetry

Core tool settlement emits:

```text
[:tackle, :tool, :execution, :start]
[:tackle, :tool, :execution, :stop]
[:tackle, :tool, :execution, :exception]
```

Metadata is deliberately bounded. Tool names are reported only when the host
places the allowed names under `state.context.telemetry.tool_names`; other names
become `"other"`. Do not put prompts, tool arguments, results, or raw errors in
telemetry metadata.

`Tackle.Phoenix.Runner` additionally emits turn telemetry; see the Phoenix
README.

## JSON boundary

Tackle defaults to Elixir's built-in `JSON` module through
`Tackle.JSON.Default`. Override it only when the host needs a different
implementation:

```elixir
config :tackle, json: MyApp.JSONAdapter
```

The adapter implements `encode/1`, `encode!/1`, `decode/1`, and `decode!/1`.

## Reusing tools through Anubis MCP

With the optional `:anubis_mcp` dependency available:

```elixir
def init(_client_info, frame) do
  {:ok, Tackle.Integrations.Anubis.register_all(frame, @tools)}
end

def handle_tool_call(name, params, frame) do
  Tackle.Integrations.Anubis.dispatch(name, params, frame,
    tools: @tools,
    context: &MyApp.MCP.Context.from_frame/1
  )
end
```

The bridge registers provider-neutral schemas and dispatches through
`Tackle.Tool.settle/3`, so validation and result projection match the agent.
The host still owns MCP server startup, OAuth, scopes, tenant resolution, and
the list of tools exposed on that surface.

## Persistence patterns

Tackle state is immutable and in memory. There is no Ecto schema or serialization
format. A host normally persists these message fields:

- stable message ID;
- role and content;
- thinking, if policy allows storing it;
- native tool calls;
- `tool_call_id` and tool name for results;
- timestamp;
- normalized usage and model;
- sequence/position within the session.

On reload, rebuild `%Tackle.Message{}` values in sequence and create a fresh
`Tackle.State` with the current trusted tool list, prompt, adapter config, and
authorization context. Do not deserialize an old context from the database and
trust it as current authorization.

Two supported persistence approaches are:

1. **Hooks in a core-only host.** Persist finalized messages in
   `after_message/3` and settle the session in `after_turn/2`.
2. **`Tackle.Phoenix.Store`.** Let the generic Runner own process lifecycle while
   the Store gates, enriches, persists, bills, and recovers the turn.

ExampleHost combines incremental hook persistence with Store-level write-ahead
pending assistant rows and terminal recovery. That is a host reliability policy,
not a requirement of core Tackle.

## ExampleHost reference implementation

The current host is a useful example of where each concern belongs:

| Concern | ExampleHost implementation | Reusable lesson |
|---|---|---|
| Adapter configuration | `config/config.exs` | Configure `:tackle, :llm` |
| Provider adapter | `lib/my_app/ai/tackle_adapter.ex` | Translate structured messages/tools at one boundary |
| Agent factory/facade | `lib/my_app/agent/agent.ex` | Centralize defaults, tools, prompt, hooks, and auth reconstruction |
| Prompt composition | `lib/my_app/agent/system_prompt.ex` | Keep domain guidance in the host |
| Tool registry | `lib/my_app/agent/tools.ex` | Build explicit surface/role-specific allowlists |
| Concrete tools | `lib/my_app/agent/tools/` | Put tenant checks in host tools |
| Core-only persistence hook | `lib/my_app/agent/hooks/persistence.ex` | Persist finalized messages idempotently |
| OTP/Phoenix facade | `lib/my_app/agent/session.ex` | Hide Runner config behind a host API |
| Persistence/quota/billing | `lib/my_app/agent/session_store.ex` | Implement `Tackle.Phoenix.Store` |
| Ecto session/message mapping | `lib/my_app/agent/sessions.ex` | Rebuild state from durable ordered messages |
| LiveView rendering | `lib/my_app_web/live/agent_panel_live.ex` and `agent_sessions_live/show.ex` | Subscribe to PubSub and reduce events |
| Message presentation | `lib/my_app_web/components/agent_chat.ex` | Implement `Tackle.Phoenix.MessageView` |
| MCP tool reuse | `lib/my_app_web/mcp/registry.ex` | Expose an explicit safe subset |
| OpenTelemetry bridge | `lib/my_app/telemetry/open_telemetry/agent_workflow.ex` | Export bounded generic telemetry |
| Durable child agents | `lib/my_app/agent/subagents.ex` | Build orchestration host-side with tools + storage |

### End-to-end ExampleHost turn

1. A LiveView derives `current_scope`, organization, permissions, locale, and
   current page context.
2. `MyApp.Agent.Session.run_turn/4` loads/reuses the per-user/session
   Runner.
3. `SessionStore.before_turn/2` re-authorizes a persisted session and checks the
   organization subscription limit before provider work.
4. `SessionStore.enrich_state/3` injects trusted persistence, authorization, and
   telemetry context.
5. The Runner writes the user message, creates a cancellation signal, and starts
   `MyApp.Agent.continue/2` under `Task.Supervisor.async_nolink`.
6. Tackle calls `MyApp.AI.TackleAdapter`, which lowers structured
   messages and native tool definitions to OpenRouter.
7. Domain tools query through the permission context. The Runner broadcasts
   normalized events and aggregates usage.
8. The LiveView uses `Tackle.Phoenix.EventReducer` and the host MessageView to
   render streaming and finalized messages.
9. `SessionStore.settle_turn/4` persists final messages, marks interrupted rows
   when needed, charges organization usage, and settles child-agent state.
10. The Runner broadcasts the terminal result and cleans up the cancellation
    signal.

### What to copy and what to redesign

Copy the **boundaries**, not ExampleHost's domain code:

- copy/adapt the `Tackle.LLM`, `Tackle.Tool`, `Tackle.Hook`, and
  `Tackle.Phoenix.Store` patterns;
- keep your own user/tenant scope, persistence schemas, quotas, and billing;
- expose separate tool lists per surface and role;
- reconstruct authorization from trusted identity on every resumed session;
- preserve structured messages and tool-call linkage;
- keep event transport and UI rendering outside core Tackle.

ExampleHost's datasets, reports, video tools, subscription credits, and subagent
policies are examples, not Tackle requirements.

## Important limitations

Tackle does **not** provide:

- a provider SDK or default model;
- persistence or a database schema;
- authentication, authorization, tenant scoping, quotas, or billing;
- concrete tools;
- provider-side parallel tool execution;
- forced tool selection or weighted/allow-deny tool policies;
- preemptive cancellation of code that ignores its signal;
- automatic provider retries/backoff;
- distributed process discovery or a cluster-wide session registry;
- built-in parent/child orchestration; or
- a complete chat UI.

`Tackle.Phoenix.Chat` is currently a documented scaffold, not a working LiveView
mixin. Use `Tackle.Phoenix.EventReducer` directly as shown in the Phoenix README.

## Porting checklist

- [ ] Copy/extract `packages/tackle` and optionally `packages/tackle_phoenix`.
- [ ] Configure a `Tackle.LLM` adapter.
- [ ] Verify the adapter preserves structured messages and tool-call IDs.
- [ ] Define tools with narrow, tenant-aware context.
- [ ] Build explicit tool lists per role/surface.
- [ ] Compose a domain system prompt.
- [ ] Decide whether state is ephemeral or durable.
- [ ] For durable state, define message ordering and idempotent writes.
- [ ] Gate quotas/permissions before starting provider work.
- [ ] Implement usage pricing/billing in the host.
- [ ] Observe cancellation in adapters and long-running tools.
- [ ] Subscribe to events for UI/transport; keep callbacks fast.
- [ ] Attach bounded telemetry without prompts or tool payloads.
- [ ] Add fake-adapter tests for success, tool calls, errors, retry, and cancel.
- [ ] If using Phoenix, follow [`../tackle_phoenix/README.md`](../tackle_phoenix/README.md).

## Source guide

Start with these files:

- `lib/tackle.ex` — public facade
- `lib/tackle/loop.ex` — authoritative lifecycle
- `lib/tackle/state.ex` and `lib/tackle/message.ex` — in-memory model
- `lib/tackle/llm.ex` — provider contract
- `lib/tackle/tool.ex` and `lib/tackle/tool/schema.ex` — tool contract
- `lib/tackle/hook.ex` and `lib/tackle/event.ex` — extension/streaming seams
- `lib/tackle/cancellation.ex` — cooperative cancellation
- `lib/tackle/snapshot.ex` — per-turn configuration stability
- `lib/tackle/integrations/anubis.ex` — optional MCP bridge
