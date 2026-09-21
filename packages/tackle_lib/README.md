# Tackle.Lib

Tackle.Lib is a small, provider-agnostic agent harness for Elixir. It provides the
framework-free core of a tool-using LLM agent and leaves provider access,
persistence, authorization, billing, concrete tools, and UI to the host
application.

This document has two goals:

1. describe the complete Tackle.Lib surface and its limits; and
2. explain reusable host integration patterns for building an agent in another
   application.

For an OTP/Phoenix runtime with supervised turns, PubSub, and LiveView stream
support, also read [`../tackle_phoenix/README.md`](../tackle_phoenix/README.md).

## Status and installation

Tackle.Lib currently lives as an in-repo Mix package. It is not published to Hex and
the repository root is a different Mix project. To use it in another project
today, either:

- copy/extract `packages/tackle_lib` into that project and use a path dependency; or
- extract the package to its own Git repository, then use a normal Git dependency.

For a copied package under `packages/tackle_lib`:

```elixir
# mix.exs
defp deps do
  [
    {:tackle_lib, path: "packages/tackle_lib"}
  ]
end
```

Tackle.Lib requires Elixir `~> 1.18`, includes `:telemetry` for its bounded
lifecycle events, and uses `:jsv` for standards-compliant JSON Schema output
validation. Exposing Tackle.Lib tools through Anubis MCP is a separate
package ([`../tackle_anubis`](../tackle_anubis/README.md)); the core library has
no MCP dependency.

## Which package do I need?

| Use case | Package |
|---|---|
| CLI command, Oban job, test, or one synchronous turn | `tackle_lib` |
| Your application already owns processes and persistence | `tackle_lib` |
| Supervised background turns with cancellation and PubSub | `tackle_lib` + `tackle_phoenix` |
| Incrementally rendered LiveView chat | `tackle_lib` + `tackle_phoenix` |
| Expose the same tools through Anubis MCP | `tackle_anubis` (brings `tackle_lib`) |

## Architecture

```text
host application
  ├── LLM/provider adapter ─────────────── implements Tackle.Lib.LLM
  ├── concrete domain tools ───────────── implements Tackle.Lib.Tool
  ├── prompt and prompt renderer ──────── implements Tackle.Lib.PromptRenderer (optional)
  ├── persistence/auth/billing/UI ─────── host-owned
  ├── credential store implementation ── host-owned, accessed by opaque handle
  │
  └── Tackle.Lib
      ├── State + Message + Usage
      ├── per-turn Snapshot
      ├── Loop
      │   ├── structured provider messages
      │   ├── native tool calls
      │   ├── hooks and events
      │   └── cooperative cancellation
      ├── provider-neutral tool schemas
      └── integration registry for host-owned bridges
```

The central boundary is intentional: Tackle.Lib knows **how** to run an agent turn,
but not which provider, user, tenant, database, or business policy is involved.

## Five-minute core example

### 1. Implement an LLM adapter

```elixir
defmodule MyApp.AI.TackleAdapter do
  @behaviour Tackle.Lib.LLM

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

Configure it under Tackle.Lib's own OTP application key when the host uses one
application-wide default:

```elixir
# config/config.exs
config :tackle_lib, llm: MyApp.AI.TackleAdapter
```

There is deliberately no built-in default adapter. A host that makes multiple
adapters available should instead implement adapter metadata and select one per
state:

```elixir
def adapter_id, do: "openai-codex"
def models, do: ["gpt-5.5", "gpt-5.5-mini"]

{:ok, llm} =
  Tackle.Lib.LLM.select(
    [MyApp.AI.CodexAdapter, MyApp.AI.AnthropicAdapter],
    "openai-codex/gpt-5.5"
  )

state = Tackle.Lib.new(llm: llm)
```

The canonical reference selects the adapter, while only the adapter-local model
id (`"gpt-5.5"`) is passed as `opts[:model]`. Selection is explicit state, not
application-global mutation, so concurrent sessions can use different adapters.

### 2. Define a tool

```elixir
defmodule MyApp.Agent.Tools.SearchDocuments do
  use Tackle.Lib.Tool

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
`{:ok, result}` or `{:error, reason}`. Expected failures should not raise. Hosts
that expose tools across a public boundary should validate their tool modules
(e.g. with `Tackle.Lib.Tool.Registry.new/1`) before they are placed in state.

### 3. Compose a prompt and run the agent

```elixir
tools = [MyApp.Agent.Tools.SearchDocuments]

authoring_prompt =
  Tackle.Lib.SystemPrompt.new()
  |> Tackle.Lib.SystemPrompt.add_section("Role", "You answer from verified documents.")
  |> Tackle.Lib.SystemPrompt.add_tools(tools)
  |> Tackle.Lib.SystemPrompt.add_response_format()
  |> Tackle.Lib.SystemPrompt.to_string()

state =
  Tackle.Lib.new(
    model: "provider/model-name",
    tools: tools,
    system_prompt: authoring_prompt,
    context: %{scope: current_scope}
  )

case Tackle.Lib.run(state, "What changed this week?") do
  {:ok, final_state} ->
    IO.puts(Tackle.Lib.last_answer(final_state))

  {:error, failed_state} ->
    IO.warn(Tackle.Lib.error(failed_state))

  {:cancelled, cancelled_state} ->
    IO.warn(cancelled_state.error)
end
```

`Tackle.Lib.run/3` is synchronous. A host that needs a long-lived or cancellable UI
turn should run it in a supervised process; `tackle_phoenix` provides that
runtime.

## What is possible with Tackle.Lib?

Tackle.Lib can be used to build:

- multi-step ReAct agents that call zero or more native provider tools;
- single-turn assistants with no tools;
- CLI, background-job, API, and Phoenix/LiveView agents;
- streaming UIs using provider-independent lifecycle events;
- tenant-aware tools by passing a host authorization object in `state.context`;
- durable conversations by mapping `Tackle.Lib.Message` to host storage;
- quota and billing systems using normalized per-step `Tackle.Lib.Usage`;
- audit and persistence extensions through lifecycle hooks;
- provider-switchable agents through the `Tackle.Lib.LLM` behaviour;
- prompt variants through `Tackle.Lib.PromptRenderer`;
- tools reused by an agent and an MCP server through the `tackle_anubis` bridge;
- parent/child or other orchestration models implemented by host tools and
  persistence; and
- deterministic tests through injected ID generators and fake LLM adapters.

A production host can use all of the important seams: place provider access
behind an adapter, pass tenant-aware permission context to domain tools, persist
messages with Ecto, gate and bill turns, stream Phoenix events to the UI, and
expose selected tools through MCP.

## Public API

### Building and running state

```elixir
state = Tackle.Lib.new(opts)
Tackle.Lib.run(state, user_input, run_opts)
Tackle.Lib.continue(state, run_opts)
```

`Tackle.Lib.new/1` accepts:

| Option | Purpose | Default |
|---|---|---|
| `:llm` | Selection returned by `Tackle.Lib.LLM.select/2` | configured adapter fallback |
| `:model` | Model identifier for a legacy configured adapter | `nil` |
| `:tools` | Modules implementing `Tackle.Lib.Tool` | `[]` |
| `:system_prompt` | Complete host-composed system prompt | `nil` |
| `:context` | Opaque host context passed to hooks and tools | `%{}` |
| `:max_iterations` | Optional maximum LLM/tool loop iterations | `:infinity` (unlimited) |
| `:hooks` | Modules implementing `Tackle.Lib.Hook` | `[]` |
| `:tool_policy` | Tool execution policy | sequential default |
| `:llm_opts` | Additional adapter options | `[]` |
| `:prompt_renderer` | Prompt renderer module | configured/default renderer |
| `:prompt_renderer_opts` | Renderer options | `[]` |
| `:id_generator` | Zero-arity session/message/tool-call ID function | UUID generator |
| `:retry` | `Tackle.Lib.Retry`, options, or `false` for provider-message retries | 3 retries, 2s base, 60s cap |

Pass a positive integer as `:max_iterations` when a host needs a bounded run.

`Tackle.Lib.run/3` appends one user message. `Tackle.Lib.continue/2` does **not** append a
message; it clears the error/status, resets the iteration budget, and retries
the existing conversation. This is the correct primitive for a Retry button
after the user's message has already been recorded.

Run options:

| Option | Purpose |
|---|---|
| `:event_callback` | Receives `%Tackle.Lib.Event{}` values |
| `:llm_stream` | Uses adapter `stream/3`, with generate fallback |
| `:cancellation_signal` | Cooperative cancellation handle |

Results are always one of:

```elixir
{:ok, %Tackle.Lib.State{status: :completed}}
{:error, %Tackle.Lib.State{status: :error}}
{:cancelled, %Tackle.Lib.State{status: :cancelled}}
```

Convenience readers are `Tackle.Lib.last_answer/1`, `Tackle.Lib.messages/1`,
`Tackle.Lib.usage/1`, `Tackle.Lib.context_usage/1`, `Tackle.Lib.completed?/1`,
`Tackle.Lib.error?/1`, and `Tackle.Lib.error/1`.

### Turn lifecycle

A normal tool-using turn is:

```text
capture immutable snapshot
emit turn_start
append + finalize user message
repeat until final answer (or a configured max_iterations):
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

Implement `Tackle.Lib.LLM`:

```elixir
@callback adapter_id() :: String.t()
@callback models() :: [String.t()]
@callback model_info(model :: String.t()) :: Tackle.Lib.ModelInfo.t() | map() | nil

@callback generate(schema :: keyword() | map() | nil, opts :: keyword()) ::
            {:ok, response} | {:error, term()}

@callback stream(schema, opts, event_callback) ::
            {:ok, response} | {:error, term()}

# Optional account flow, owned end-to-end by the adapter.
@callback login(opts :: keyword()) :: {:ok, credentials :: map()} | {:error, term()}
@callback logout(opts :: keyword()) :: :ok | {:error, term()}
@callback status(opts :: keyword()) :: {:ok, term()} | {:error, term()}
@callback usage(opts :: keyword()) :: {:ok, report :: map()} | {:error, term()}
```

`adapter_id/0` and `models/0` are required for adapters passed to
`Tackle.Lib.LLM.select/2`. They remain optional for compatibility with a single
adapter configured through `config :tackle_lib, :llm`. Adapter ids are lowercase
letters, digits, and hyphens and must be unique in the supplied adapter list.

`model_info/1` is optional. It may return a context window, maximum output token
count, and adapter-owned price card. `Tackle.Lib.LLM.select/2` validates and
freezes this metadata in the selection. `Tackle.Lib.LLM.model_info/2` is the safe
callback boundary for callers that need explicit callback/validation errors.
Price-card cost is marked estimated; a numeric provider-reported total remains
authoritative.

Hosts may inject a `{module, reference}` credential-store handle in
`opts[:credential_store]`. Adapters access their own namespace with
`Tackle.Lib.CredentialStore.fetch/2`, `put/3`, and `delete/2`. Tackle.Lib treats
credential maps as opaque JSON-compatible data; OAuth flows, token schemas,
refresh logic, and persistence remain outside the library.

### Account flows

The optional `login/1`, `logout/1`, `status/1`, and `usage/1` callbacks let an
adapter own its complete account lifecycle so a frontend never hard-codes
provider knowledge:

- `login/1` runs the interactive flow (device code, browser hand-off, API-key
  prompt) and returns credentials to store. The host passes a
  `Tackle.Lib.Interaction` handle in `opts[:interaction]`; the adapter calls
  `info/2`, `prompt/2`, `confirm/2`, and `progress/3` on it instead of depending
  on a terminal library.
- `logout/1` revokes or removes credentials. When omitted, the host deletes the
  credentials stored under `adapter_id/0`.
- `status/1` reports credential state. When omitted, the host reads the
  credential store and returns `{:ok, :stored} | {:ok, :missing}`.
- `usage/1` returns a host-renderable map (plan, balance, rate-limit windows).
  Adapters with no account endpoint omit it.

The host resolves adapters by `adapter_id/0`, injects `:interaction`,
`:credential_store`, and any supplied options, and stores the map returned by
`login/1`. Example:

```elixir
@impl true
def login(opts) do
  with {:ok, interaction} <- Keyword.fetch(opts, :interaction),
       :ok <- Tackle.Lib.Interaction.info(interaction, "Open the provider portal."),
       {:ok, token} <-
         Tackle.Lib.Interaction.prompt(interaction, label: "API token", secret: true) do
    {:ok, %{"token" => token}}
  end
end
```

`stream/3` is optional. When absent, Tackle.Lib calls `generate/2` and still emits a
normalized usage event when usage is returned.

The loop supplies these adapter options:

- `:model`
- `:session_id` — stable across the conversation for provider cache affinity
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
    # Present only when the adapter returned opaque continuation metadata.
    provider_state: %{"provider" => "example", "model" => "model-name", "opaque" => "..."},
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
   provider: "provider",
   provider_state: %{"provider" => "provider", "model" => "provider/model-name", "opaque" => "..."}
 }}
```

`:usage` may already be `%Tackle.Lib.Usage{}`, a string- or atom-keyed provider map,
or `nil`. Tackle.Lib normalizes it. Adapter price cards may fill an itemized and
total estimate when the provider omits cost; hosts still own billing, quota, and
persistence policy.

`:provider_state` is optional opaque, non-secret continuation metadata needed by
some stateless provider APIs. Tackle.Lib stores it on the assistant message and
returns it in subsequent `opts[:messages]`; an adapter must replay it only when
its embedded provider and model match the current request. Hosts that persist
conversations must preserve this field.

Provider adapters are also responsible for translating Tackle.Lib's normalized
tool definitions into the provider wire format. `opts[:tools]` contains
serializable `:input_schema` field maps. In code that still has a tool module's
native keyword schema, `Tackle.Lib.Tool.Schema.JsonSchema.to_json_schema/1` provides
the standard JSON Schema projection. `JsonSchema.validate_output/2` validates
JSON Schema maps using JSV and Draft 2020-12.

## Tool system

### Behaviour and DSL

A manual tool implements:

- `name/0`
- `description/0`
- `parameters_schema/0`
- `execute/2`
- optional `output_schema/0`
- optional `description_metadata/0`

`use Tackle.Lib.Tool` generates the standard callbacks from the DSL and delegates
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
are treated as absent. Tackle.Lib never creates atoms from provider/user keys.

### Settlement and errors

`Tackle.Lib.Tool.settle/3` is the canonical local execution pipeline:

1. normalize and validate arguments;
2. execute the host tool;
3. validate output when a schema exists;
4. preserve the raw result for host events;
5. project the result to text/JSON for the model transcript.

A tool that also produces non-text content returns `%Tackle.Lib.Tool.Content{}`
from `execute/2`. Settlement then keeps its text projection as the transcript's
string `content` (what human-facing surfaces and token estimates read) and
carries its extra parts — currently images — on
`Tackle.Lib.Tool.Result.parts` and the linked message's `parts`. `to_provider/1`
turns those into a provider-neutral content-part array that adapters lower into
their wire format; text-only adapters degrade the parts explicitly.

Do not bypass settlement in custom runtimes. It is what keeps agent and MCP
execution consistent.

Expected tool failures return `{:error, reason}`. Tackle.Lib converts them into a
linked tool result with sanitized model-facing content while detailed failure
information remains available in `:tool_error` events. Exceptions are rescued
and logged as bugs; they should not be normal control flow.

Unknown tools and stale `definition_id` values settle as typed errors rather
than executing a different definition. Tool names must be unique in a registry.
Definitions and tool sets have deterministic SHA-256-derived IDs for audit and
cache keys.

### Tool execution modes

Tackle.Lib supports two tool execution modes. They differ only in **when** the
calls in a single model-requested batch run; both always append tool results in
the exact order the model requested them.

|                                        | `:sequential` (library default) | `:concurrent`                            |
| -------------------------------------- | ------------------------------- | ---------------------------------------- |
| Batch execution                        | one call at a time              | every call starts together               |
| Supervisor required                    | no                              | yes — the `:tool_supervisor` run option  |
| Tool result order                      | requested order                 | requested order                          |
| Events                                 | `tool_start`/`tool_end` interleave per call | all `tool_start` first, execution progress per worker, settlement in order |
| Tool crash                             | normal turn error path          | becomes a tool error; siblings continue  |
| Cancellation                           | calls not yet started are skipped | in-flight tasks are shut down          |
| `before_tool_call` hooks               | immediately before each call    | for the whole batch before any call      |
| `after_tool_call` hooks                | per call, threading context     | after the batch, in requested order      |
| Side-effect ordering within the batch  | requested order                 | none between calls                       |

Both modes are correct for **independent** calls — reads, edits to different
files, standalone commands — which is why concurrency is a good default when the
host can supply a supervisor.

Sequential is the safer choice when:

* calls in one batch may have ordered side effects (an edit followed by a shell
  command that uses the file, or two shell commands), because concurrency gives
  no ordering between them;
* a tool is unsafe to overlap (shells contending for `git`, package managers,
  bound ports, or code evaluated inside the live BEAM);
* the host wants the trivial resource bound instead of adding its own pool; or
* the host does not run OTP supervision and cannot supply a `Task.Supervisor`.

**Tackle.Lib defaults to `:sequential`** so any host can run a turn without OTP
supervision. The Tackle harness pins `:concurrent` for every session and
supplies a per-session tool supervisor; `Tackle.Config` does not accept a
`:tool_policy` option.

```elixir
# Library default: sequential, no supervisor needed.
state = Tackle.Lib.new(tools: tools)

# Opt in to concurrency under a host-owned supervisor.
state = Tackle.Lib.new(tools: tools, tool_policy: Tackle.Lib.Tool.Policy.concurrent())

Tackle.Lib.run(state, "apply every fix", tool_supervisor: MyApp.ToolTaskSupervisor)
```

In `:concurrent` mode each call runs as a task under the supplied
`Task.Supervisor`. A tool crash becomes a tool error result, cancellation shuts
the batch down, and results are still appended in call order. The supervisor is
host-owned so one agent session cannot leak tasks into another; the library
raises if `:concurrent` is configured without a `:tool_supervisor`.

Either mode may still select its tools up front. Tackle.Lib intentionally does
not support forced tool choice, provider-side parallel tool calls, allow/deny
options, or weighting. These keys are removed from `llm_opts`:

- `:tool_choice`
- `:parallel_tool_calls`
- `:allowed_tools`
- `:disallowed_tools`
- `:tool_weights`
- `:tool_policy`

Select allowed tools before the turn by constructing a tenant/user-scoped tool
list. Do not rely on provider options as the authorization boundary.

## Context and authorization

`Tackle.Lib.State.context` is an opaque host map. Tackle.Lib passes it through hooks and
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

Tackle.Lib does not authorize this data. The host must derive trusted context from
the authenticated request or persisted session, and every data-holding tool
must enforce the tenant boundary itself. A durable host should reconstruct
authorization from persisted user and tenant data before every turn rather than
trusting browser-supplied IDs.

## Hooks

Implement `Tackle.Lib.Hook` to observe or mutate context at stable lifecycle points:

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
metadata, and cleanup. Hosts can use `after_message/3` and `after_turn/2` for
idempotent message persistence and title generation.

Do not use hooks as a substitute for tool authorization. A hook can abort a
turn, but the tool remains the final security boundary for its operation.

## Events and streaming

Pass `event_callback: fn event -> ... end` to receive provider-independent
events. Event types include:

- `:turn_start`, `:turn_end`, `:turn_cancelled`
- `:step_start`, `:step_end`
- `:message_start`, `:message_delta`, `:message_end`
- `:tool_start`, `:tool_progress`, `:tool_execution_end`, `:tool_end`, `:tool_error`
- host-defined lifecycle events such as `:subagent_started`, `:subagent_progress`, and `:subagent_finished`
- `:usage`, `:status_change`, `:error`
- `:retry_scheduled`, `:retry_start`, `:retry_end`
- `:provider_event` for unrecognized provider data

Every event is `%Tackle.Lib.Event{type, id, parent_id, data, timestamp, metadata}`.
Streaming text, reasoning, tool-input, usage, and provider errors are normalized
through `Tackle.Lib.Event.normalize/2`. The loop stamps streamed message deltas with
the message ID minted at `:message_start`, allowing a UI to route concurrent
in-flight display state safely.

Reasoning and tool-input deltas are tagged in event data. A user-facing UI
should not append them to the visible answer bubble by default. The
`tackle_phoenix` event reducer follows this rule.

Host tools may emit transient `:tool_progress` events through the callback in
their execution context. Progress should carry `tool_call_id`, `name`, and a
bounded `delta`; it is presentation data and is replaced by the canonical
`:tool_end` or `:tool_error` settlement.

`:tool_execution_end` reports each completed execution as the loop collects its
worker result, without waiting for the rest of a concurrent batch. It carries
`tool_call_id`, `name`, and `status` (`:completed` or `:failed`), plus `result`
on success or `error`/`reason` on failure. Sequential execution emits it too.
These are transient progress events, not persistence acknowledgements: they may
arrive out of provider order, before transcript commits, and tools terminated by
cancellation without a result do not emit one. The existing `:tool_end` and
`:tool_error` events still follow ordered message finalization; hooks and model
history remain in provider order. UIs should update the same row by call ID when
both progress and settlement arrive.

Event callbacks should be fast. Send events to another process or PubSub rather
than doing slow database work in the callback; use hooks or the Phoenix Store
settlement seam for durable work.

## Provider retries

Transient provider-message failures are retried around the current generation,
not around the whole turn. The default policy makes at most three retries with
deterministic exponential delays of 2, 4, and 8 seconds (capped at 60 seconds).
Configure it per state:

```elixir
Tackle.Lib.new(
  retry: [max_retries: 3, base_delay_ms: 2_000, max_delay_ms: 60_000]
)
```

Use `retry: false` or `max_retries: 0` to disable retries. Context overflow is
classified first and retains its compact-and-retry path. Cancellation,
authentication, quota/billing, context overflow, and unknown failures are never
transient retries; hooks, tools, compaction commits, and other persistence also
remain outside this policy. The backoff wait cooperatively polls the turn's
cancellation signal.

A retry reuses the same provider messages, pending assistant message ID, and
loop iteration. It does not append a second user message. Hosts rendering
streaming deltas should clear output for the pending assistant ID when they
receive `:retry_scheduled`, before the next attempt emits more deltas.

Retry lifecycle data includes the one-indexed `attempt`; `:retry_scheduled` also
includes `max_retries`, `delay_ms`, and `reason`, while the single terminal
`:retry_end` includes `success?` and the final `reason` on failure.

## Cooperative cancellation

```elixir
signal = Tackle.Lib.Cancellation.new_signal()

Task.start(fn ->
  Tackle.Lib.run(state, input,
    cancellation_signal: signal,
    llm_stream: true
  )
end)

Tackle.Lib.Cancellation.cancel(signal, :user_cancelled)
```

The loop checks cancellation before work, after LLM calls, and between tool
calls. The adapter receives the signal in its opts and tools receive it in
context. Long-running adapters and tools should check
`Tackle.Lib.Cancellation.cancelled?/1` and abort their own work.

Cancellation is cooperative, not preemptive. Tackle.Lib cannot interrupt code that
ignores the signal. Delete signals after terminal settlement with
`Tackle.Lib.Cancellation.delete/1`; `Tackle.Phoenix.Runner` manages this lifecycle
automatically.

The cancellation store is configurable:

```elixir
config :tackle_lib, cancellation_store: MyApp.CancellationStore
```

It defaults to an ETS-backed implementation that supports cross-process access
on one BEAM node.

## Prompts and structured non-tool responses

The host owns the domain prompt. `Tackle.Lib.SystemPrompt` only provides composable
structure:

- `new/0`
- `add_section/3`
- `add_raw/2`
- `add_tools/3`
- `add_response_format/2`
- `to_string/1`
- `version_id/1`

`Tackle.Lib.PromptRenderer` controls how tools and response guidance are rendered and
may return a response schema for a structured **non-tool** turn. Tool execution
always uses provider-native tool calls. The built-in
`Tackle.Lib.PromptRenderer.NativeTools` is the default.

A host may implement `description_metadata/0` on tools and render the same
structured documentation differently for web prompts and MCP—for example,
Markdown for a web agent and XML-oriented descriptions for MCP while sharing
the same tool modules.

The loop sends the persisted user, assistant, and tool messages without adding
synthetic per-step messages. Provider context therefore remains append-only
across tool calls. Put loop-wide behavioral guidance in the stable system prompt
rather than at the end of each request.

## Snapshots and configuration stability

At the start of a turn Tackle.Lib captures `%Tackle.Lib.Snapshot{}` containing the
explicit adapter/model selection (or the compatible configured default),
tools/registry, hooks, prompt, prompt renderer, and LLM options. That turn
continues against the frozen snapshot even if application configuration or code
registration changes while it runs.

Snapshots include deterministic `system_prompt_version_id` and
`tools_version_id` values. Persist those IDs in host audit records when you need
to explain which configuration a turn used. The snapshot itself is cleared from
state during terminal cleanup.

## Prompt caching

`Tackle.Lib.Cache` adds provider-compatible cache-control markers to the stable
request prefix:

```elixir
Tackle.Lib.new(llm_opts: [cache: true])
```

Adapters opt in by calling:

```elixir
control = Tackle.Lib.Cache.control(opts)
messages = Tackle.Lib.Cache.mark_system(messages, control)
tools = Tackle.Lib.Cache.mark_last_tool(tools, control)
```

This only marks cache breakpoints; it does not store or evict cached content.
Providers that ignore the marker are unaffected. The loop also sends the stable
state `:session_id` to every adapter so providers with cache-affinity keys can
reuse the same cache route across steps and turns. A host may enable explicit
cache markers for any agent whose provider supports them.

## Context compaction

`Tackle.Lib.Compaction` replaces the **provider-visible projection** when a long
session approaches the model's context window. It never touches the canonical
transcript: `State.messages` stays complete, while `State.model_messages` becomes a
synthetic checkpoint plus a recent structurally valid tail. The planner walks
backward toward the retention target and may split an oversized turn at an
assistant boundary rather than keeping that entire turn. Retained content and
tool linkage stay intact, while stale usage and provider continuation metadata
are cleared at the new context boundary.

Compaction is opt-in. Supply a config when building state:

```elixir
state =
  Tackle.Lib.new(
    llm: selection,
    compaction: [
      summarizer: Tackle.Lib.Compaction.Summarizer.LLM,
      committer: MyApp.CompactionCommitter,
      policy: [safety_reserve: 4_096, retain_ratio: 0.16]
    ]
  )
```

Entry points share one transaction:

- automatic `:pressure` compaction before every provider generation, at the
  model's resolved threshold;
- one `:overflow` compact-and-retry after a provider
  `{:error, :context_window_exceeded}`; and
- `Tackle.Lib.compact/2` for an idle, operator-requested compaction.

A `Tackle.Lib.Compaction.Summarizer` only turns a request into text plus usage.
It receives the state's host-supplied `llm_opts` (including credential-store
handles); explicit compaction `:llm_opts` are merged on top. The core owns
balanced cut selection, strict validation (non-empty, complete, no tool calls,
strictly smaller than the shadowed region), the durability commit, and the
in-memory replacement. A `Tackle.Lib.Compaction.Committer` makes the record
durable before replacement; a commit failure is reported as
`{:error, {:durable_commit_failed, reason}}` so a host can fail closed.

Lifecycle events `:compaction_start`, `:compaction_end`, and `:compaction_retry`
carry trigger, before/after estimates, counts, duration, and summary model/usage.
They never include raw prompts or summary content. `ContextUsage` reads the model
projection, and retained assistant usage is stripped from it because it no longer
describes the current request. Treat compaction as the start of a new prompt-cache
reuse sequence.

## Conversation trees

`Tackle.Lib.Tree` is an optional, pure conversation tree for sessions that need
alternative paths. It is opt-in and needs no process, storage, or OTP
supervision:

```elixir
state = Tackle.Lib.new(llm: selection, tree: true, tree_committer: MyApp.TreeCommitter)
{:ok, state} = Tackle.Lib.run(state, "investigate the cache")

# Move to the parent of an earlier user message; the selected message comes back
# as a draft so the host can refill its editor and create a sibling branch.
{:ok, state, outcome} = Tackle.Lib.navigate(state, {:edit, user_message_id})
outcome.draft.content

# Return to the empty conversation before the first message.
{:ok, state, _outcome} = Tackle.Lib.navigate(state, nil)
```

Every settled message and committed compaction becomes an entry with a stable id
and an optional parent link. Message entries reuse the message id and compaction
entries reuse the compaction id, so identity matches the rest of the harness and
is unique across kinds.

Three readers stay deliberately distinct:

- `Tackle.Lib.Tree.enumerate/1` — every entry on every branch, once, in
  chronological order (the whole-tree archive);
- `Tackle.Lib.messages/1` — the active path's complete, uncompacted transcript;
  and
- `Tackle.Lib.model_messages/1` — the active path's provider context, with only
  the compactions that occur on that path applied.

Accordingly, `Tackle.Lib.usage/1` aggregates assistant usage across the whole
archive while `Tackle.Lib.branch_usage/1` follows the active path, and
`Tackle.Lib.context_usage/1` measures the selected model projection. A compaction
on one branch never changes a sibling's context, and returning after a
compaction restores the same summary without re-summarizing.

Navigation never runs a turn, re-executes a tool, or edits entries. It validates
the destination against the current revision, rejects a structurally incomplete
tool batch with `{:error, {:unsafe_continuation, id}}`, and commits through a
`Tackle.Lib.Tree.Committer` before installing the position. A missing committer
is valid only for explicitly in-memory use. Failed validation or commit leaves
the accepted state unchanged. `Tackle.Lib.Tree.restore/2` is the validated
restoration path for hosts that persist their own entries.

Linear mode is unchanged: without `tree: true`, `State.messages` remains the
entire conversation archive, as before.

## Usage and billing

Each assistant generation may carry `%Tackle.Lib.Usage{}` with input, output,
reasoning, cache-read, cache-write, total tokens, optional cost/currency, model,
provider, and raw provider metadata. The input/cache buckets are disjoint. `Tackle.Lib.Usage.prompt_tokens/1` sums
them, while `Tackle.Lib.Usage.cache_hit_rate/1` returns the raw cached share of
prompt volume:

```text
cache_read_tokens / (input_tokens + cache_read_tokens + cache_write_tokens)
```

That raw share includes cold-start and newly appended content. To measure cache
quality, `Tackle.Lib.Usage.cache_reuse/1` compares each checkpoint with the
preceding prompt and reports reusable, reused, and missed tokens plus the reuse
rate. `cache_reuse_rate/1` returns only that ratio. Start a new sequence after
compaction or another non-append-only context rewrite.

The metrics return `nil` when their required cache reporting or prompt usage is
unavailable. `Tackle.Lib.usage(state)` derives aggregate usage from assistant
messages so a separate mutable total cannot drift. Cost aggregation is
conservative: costs are summed only when every entry has numeric cost and
currencies are compatible; an aggregate containing any estimate is itself
estimated.

`Tackle.Lib.context_usage(state)` uses the latest non-zero assistant usage as a
checkpoint, preferring provider `total_tokens` and otherwise summing input,
output, cache-read, and cache-write exactly once. Messages after that checkpoint
are estimated at four UTF-8 characters per token. With no checkpoint, the
system prompt, messages, and provider-neutral tool definitions are estimated.
The result exposes raw remaining context and may exceed 100%; it does not reserve
output tokens or trigger automatic compaction.

Adapters own price cards because provider/model prices change independently of
the core. Tackle.Lib does not interpret subscriptions, credits, or tenants;
hosts must enforce quota **before** a turn starts. `Tackle.Phoenix.Store.before_turn/2`
and `settle_turn/4` are designed for that split.

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

Tackle.Lib defaults to Elixir's built-in `JSON` module through
`Tackle.Lib.JSON.Default`. Override it only when the host needs a different
implementation:

```elixir
config :tackle_lib, json: MyApp.JSONAdapter
```

The adapter implements `encode/1`, `encode!/1`, `decode/1`, and `decode!/1`.

## Reusing tools through Anubis MCP

The Anubis MCP bridge lives in the sibling [`tackle_anubis`](../tackle_anubis/README.md)
package (`Tackle.Anubis`), so the core library carries neither `:anubis_mcp` nor
Anubis-specific code. Add it alongside `tackle_lib`:

```elixir
# mix.exs
defp deps do
  [
    {:tackle_lib, path: "packages/tackle_lib"},
    {:tackle_anubis, path: "packages/tackle_anubis"}
  ]
end
```

```elixir
def init(_client_info, frame) do
  {:ok, Tackle.Anubis.register_all(frame, @tools)}
end

def handle_tool_call(name, params, frame) do
  Tackle.Anubis.dispatch(name, params, frame,
    tools: @tools,
    context: &MyApp.MCP.Context.from_frame/1
  )
end
```

The bridge registers provider-neutral schemas and dispatches through
`Tackle.Lib.Tool.settle/3`, so validation and result projection match the agent.
The host still owns MCP server startup, OAuth, scopes, tenant resolution, and
the list of tools exposed on that surface.

## Persistence patterns

Tackle.Lib state is immutable and in memory. There is no Ecto schema or serialization
format. A host normally persists these message fields:

- stable message ID;
- role and content;
- thinking, if policy allows storing it;
- native tool calls;
- `tool_call_id` and tool name for results;
- timestamp;
- normalized usage and model;
- sequence/position within the session.

On reload, rebuild `%Tackle.Lib.Message{}` values in sequence and create a fresh
`Tackle.Lib.State` with the current trusted tool list, prompt, adapter config, and
authorization context. Do not deserialize an old context from the database and
trust it as current authorization.

Two supported persistence approaches are:

1. **Hooks in a core-only host.** Persist finalized messages in
   `after_message/3` and settle the session in `after_turn/2`.
2. **`Tackle.Phoenix.Store`.** Let the generic Runner own process lifecycle while
   the Store gates, enriches, persists, bills, and recovers the turn.

A production host can combine incremental hook persistence with Store-level
write-ahead pending assistant rows and terminal recovery. That is a host
reliability policy, not a requirement of core Tackle.Lib.

## Example host architecture

The following generic layout illustrates where each concern belongs:

| Concern | Example implementation | Reusable lesson |
|---|---|---|
| Adapter configuration | `config/config.exs` | Configure `:tackle_lib, :llm` |
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

### End-to-end host turn

1. A LiveView derives `current_scope`, tenant, permissions, locale, and current
   page context.
2. `MyApp.Agent.Session.run_turn/4` loads or reuses the per-user/session Runner.
3. `SessionStore.before_turn/2` re-authorizes a persisted session and checks the
   tenant's quota before provider work.
4. `SessionStore.enrich_state/3` injects trusted persistence, authorization, and
   telemetry context.
5. The Runner writes the user message, creates a cancellation signal, and starts
   `MyApp.Agent.continue/2` under `Task.Supervisor.async_nolink`.
6. Tackle.Lib calls `MyApp.AI.TackleAdapter`, which lowers structured messages
   and native tool definitions to the selected provider.
7. Domain tools query through the permission context. The Runner broadcasts
   normalized events and aggregates usage.
8. The LiveView uses `Tackle.Phoenix.EventReducer` and the host MessageView to
   render streaming and finalized messages.
9. `SessionStore.settle_turn/4` persists final messages, marks interrupted rows
   when needed, charges usage, and settles child-agent state.
10. The Runner broadcasts the terminal result and cleans up the cancellation
    signal.

### What to copy and what to redesign

Copy the **boundaries**, not the example application's domain code:

- copy/adapt the `Tackle.Lib.LLM`, `Tackle.Lib.Tool`, `Tackle.Lib.Hook`, and
  `Tackle.Phoenix.Store` patterns;
- keep your own user/tenant scope, persistence schemas, quotas, and billing;
- expose separate tool lists per surface and role;
- reconstruct authorization from trusted identity on every resumed session;
- preserve structured messages and tool-call linkage;
- keep event transport and UI rendering outside core Tackle.Lib.

Datasets, reports, subscription credits, and subagent policies belong to the
host application; they are not Tackle.Lib requirements.

## Important limitations

Tackle.Lib does **not** provide:

- a provider SDK or default model;
- persistence or a database schema;
- authentication, authorization, tenant scoping, quotas, or billing;
- concrete tools;
- provider-side parallel tool execution (local `:concurrent` execution is available, but the provider is never asked to schedule calls);
- forced tool selection or weighted/allow-deny tool policies;
- preemptive cancellation of code that ignores its signal;
- automatic provider retries/backoff;
- distributed process discovery or a cluster-wide session registry;
- built-in parent/child orchestration; or
- a complete chat UI.

`Tackle.Phoenix.Chat` is currently a documented scaffold, not a working LiveView
mixin. Use `Tackle.Phoenix.EventReducer` directly as shown in the Phoenix README.

## Porting checklist

- [ ] Copy/extract `packages/tackle_lib` and optionally `packages/tackle_phoenix`.
- [ ] Configure a `Tackle.Lib.LLM` adapter.
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
- `lib/tackle_lib/loop.ex` — authoritative lifecycle
- `lib/tackle_lib/state.ex` and `lib/tackle_lib/message.ex` — in-memory model
- `lib/tackle_lib/usage.ex`, `model_info.ex`, and `context_usage.ex` — session statistics
- `lib/tackle_lib/llm.ex` — provider contract
- `lib/tackle_lib/tool.ex` and `lib/tackle_lib/tool/schema.ex` — tool contract
- `lib/tackle_lib/hook.ex` and `lib/tackle_lib/event.ex` — extension/streaming seams
- `lib/tackle_lib/cancellation.ex` — cooperative cancellation
- `lib/tackle_lib/snapshot.ex` — per-turn configuration stability
- `lib/tackle_lib/integrations/registry.ex` — registry for host-owned tool bridges
