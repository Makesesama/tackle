# Tackle.Lib

Tackle.Lib is a small, provider-agnostic agent harness for Elixir. It provides the
framework-free core of a tool-using LLM agent and leaves provider access,
persistence, authorization, billing, concrete tools, and UI to the host
application.

This document has two goals:

1. describe the complete Tackle.Lib surface and its limits; and
2. explain reusable host integration patterns for building an agent in another
   application.

For scoped agents and subagents, read
[`../tackle_runtime/README.md`](../tackle_runtime/README.md). For Phoenix turns,
PubSub, and LiveView stream support, also read
[`../tackle_phoenix/README.md`](../tackle_phoenix/README.md).

## Status and installation

Tackle.Lib is available from this Git monorepo, not Hex. Add this dependency
to your application's `mix.exs`, replacing `REF` with a published tag or commit
SHA (do not use a floating branch for a reproducible build):

```elixir
defp deps do
  [
    {:tackle_lib,
     git: "https://github.com/Makesesama/tackle.git",
     ref: "REF",
     subdir: "packages/tackle_lib"}
  ]
end
```

Then run `mix deps.get`. Mix's `:subdir` option requires Elixir 1.13 or newer;
Tackle.Lib requires Elixir `~> 1.18`. This Git-only installation is not a Hex
release. To work on the library within a checkout, use its local Mix project in
`packages/tackle_lib` instead.

Tackle.Lib requires Elixir `~> 1.18` and includes `:telemetry` for its bounded
lifecycle events. Exposing Tackle.Lib tools through Anubis MCP is a separate
package ([`../tackle_anubis`](../tackle_anubis/README.md)); the core library has
no MCP dependency.

## Which package do I need?

| Use case | Package |
|---|---|
| CLI command, Oban job, test, or one synchronous turn | `tackle_lib` |
| Your application already owns processes and persistence | `tackle_lib` |
| Scoped agents, subagents, and limits | `tackle_lib` + `tackle_runtime` |
| Supervised background turns with cancellation and PubSub | `tackle_lib` + `tackle_phoenix` |
| Phoenix subagents | `tackle_lib` + `tackle_runtime` + `tackle_phoenix` |
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

There is deliberately no built-in or application-wide default adapter. Give
the adapter metadata and select a provider and model for each state; the loop
raises `ArgumentError` for a state without a selection:

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

A model reference is `provider_id/model`. The prefix always names a
**provider**, a configured instance of an adapter; `adapter_id/0` only names the
adapter type. A bare adapter module stands for its default providers, which is
one provider whose id is `adapter_id/0` unless the adapter declares
`default_providers/0`, so `"openai-codex/gpt-5.5"` above resolves to the Codex
adapter's default provider.

The selection passes only the adapter-local model id (`"gpt-5.5"`) as
`opts[:model]`, plus the provider as `opts[:provider_id]` and
`opts[:provider_settings]`. Selection is explicit state, not
application-global mutation, so concurrent sessions can use different
providers. See [Providers](#providers) for configuring several instances of
one adapter.

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
(e.g. with `Tackle.Lib.Tool.tool?/1` or `Tackle.Lib.Tool.Registry.new/1`) before
they are placed in state.

### 3. Compose a prompt and run the agent

```elixir
tools = [MyApp.Agent.Tools.SearchDocuments]

authoring_prompt =
  Tackle.Lib.SystemPrompt.new()
  |> Tackle.Lib.SystemPrompt.add_section("Role", "You answer from verified documents.")
  |> Tackle.Lib.SystemPrompt.add_tools(tools)
  |> Tackle.Lib.SystemPrompt.add_response_format()
  |> Tackle.Lib.SystemPrompt.to_string()

{:ok, llm} = Tackle.Lib.LLM.select([MyApp.AI.TackleAdapter], "my-adapter/model-name")

state =
  Tackle.Lib.new(
    llm: llm,
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
| `:llm` | Selection returned by `Tackle.Lib.LLM.select/2`, required to run; `Tackle.Lib.State.model/1` reads its model (there is no `:model` option) | `nil` |
| `:tools` | Modules implementing `Tackle.Lib.Tool`, built into `state.tool_registry` (`Tackle.Lib.State.tools/1` lists them) | `[]` |
| `:system_prompt` | Complete host-composed system prompt | `nil` |
| `:context` | Opaque host context passed to hooks and tools | `%{}` |
| `:max_iterations` | Optional maximum LLM/tool loop iterations per turn | `:infinity` (unlimited) |
| `:hooks` | Modules implementing `Tackle.Lib.Hook`; any other entry, such as a misspelled module, raises `ArgumentError` | `[]` |
| `:tool_policy` | Tool execution policy | sequential default |
| `:llm_opts` | Additional adapter options | `[]` |
| `:prompt_renderer` | Prompt renderer module | configured/default renderer |
| `:prompt_renderer_opts` | Renderer options | `[]` |
| `:id_generator` | Zero-arity session/message/tool-call ID function | UUID generator |
| `:retry` | `Tackle.Lib.Retry`, options, or `false` for provider-message retries | 3 retries, 2s base, 60s cap |
| `:tree` | An existing `Tackle.Lib.Tree` to continue; anything else raises `ArgumentError` | empty tree |

Pass a positive integer as `:max_iterations` when a host needs a bounded run.

The state keeps no derived copies beyond the conversation caches:
`Tackle.Lib.State.model/1` reads the selection, `Tackle.Lib.State.tools/1`
reads the tool registry, and `Tackle.Lib.State.last_compaction/1` and
`last_compaction_id/1` read the compaction entries of the state's tree (see
[Conversation trees](#conversation-trees) for the `messages` and
`model_messages` caches). The loop's per-step
bookkeeping (the id of the assistant message being generated, the overflow
recoveries a turn has spent) is not on the state. A host that installs a
restored or navigated conversation on a state calls
`Tackle.Lib.State.reset_turn/1`, which clears the iteration counter, status,
and error fields the way a new turn does.

`Tackle.Lib.run/3` appends one user message. `Tackle.Lib.continue/2` does **not** append a
message; it clears the error/status, resets the iteration budget, and retries
the existing conversation. This is the correct primitive for a Retry button
after the user's message has already been recorded.

Run options (both functions take the same ones; an unknown option raises
`ArgumentError`):

| Option | Purpose |
|---|---|
| `:event_callback` | Receives `%Tackle.Lib.Event{}` values; tools also receive it in their context as `:event_callback` |
| `:tool_context` | Map merged over `state.context` for tool execution only (default `%{}`) |
| `:llm_stream` | Uses adapter `stream/3`, with generate fallback |
| `:cancellation_signal` | Cooperative cancellation handle |
| `:turn_id` | Host-assigned turn id stored on the per-turn snapshot |
| `:tool_supervisor` | `Task.Supervisor` for the `:concurrent` tool policy |
| `:take_incoming_messages` | Zero-arity callback returning `{:ok, [message]}` or `{:error, reason}`; queued user messages are appended before the next provider call |
| `:before_provider_call` | Zero-arity provider dispatch gate; returns `:ok` or `{:error, reason}` |
| `:before_tool_execution` | Zero-arity gate before tools with external effects run; returns `:ok` or `{:error, reason}` |

Results are always one of:

```elixir
{:ok, %Tackle.Lib.State{status: :completed}}
{:error, %Tackle.Lib.State{status: :error}}
{:cancelled, %Tackle.Lib.State{status: :cancelled}}
```

An error result carries a human-readable `state.error` and the structured
`state.error_reason` behind it, which the `:error` event also reports as
`:reason`: the provider's error reason (a `%Tackle.Lib.LLM.Error{}` for
provider and transport failures, a malformed adapter result, and an adapter
crash, whose message `state.error` shows), a hook's abort reason,
`:max_iterations`, `:empty_response`, and so on.
Match on `error_reason`; show `error`. A cancelled state keeps the cancellation
reason in `error`.

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
  call or stream LLM (retries, overflow recovery, one re-ask of an
    empty response); emit usage for every response
  normalize the response into %Tackle.Lib.LLM.Response{}; emit step_end
  after_prompt hook (receives the response)
  ├── final content:
  │     append assistant message; emit message_end
  │     poll queued incoming messages (continue if any)
  │     before_turn_end hooks (continue with their messages if any)
  │     emit status_change, turn_end
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

# Optional: built-in providers and per-provider (instance-aware) metadata.
@callback default_providers() :: [{provider_id :: String.t(), settings :: map()}]
@callback models(settings :: map()) :: [String.t()]
@callback model_info(model :: String.t(), settings :: map()) ::
            Tackle.Lib.ModelInfo.t() | map() | nil

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

`adapter_id/0` and either `models/1` or `models/0` are required: every call
goes through a selection, and `Tackle.Lib.LLM.select/2` needs them.
`adapter_id/0` names the adapter type: lowercase letters, digits, and inner
hyphens. It is also the id of the adapter's default provider unless the
adapter exports `default_providers/0`, which returns a non-empty list of
`{provider_id, settings}` tuples.

The arity-1 instance callbacks `models/1`, `model_info/2`, and (for decision
adapters) `decision_models/1` and `local?/1` receive the provider's settings
and are preferred over their arity-0 counterparts when exported, so one adapter
can expose different catalogs or locality per provider.

`model_info/1` is optional. It may return a context window, maximum output token
count, and adapter-owned price card. `Tackle.Lib.LLM.select/2` validates and
freezes this metadata in the selection. `Tackle.Lib.LLM.model_info/2` is the safe
callback boundary for callers that need explicit callback/validation errors.
Price-card cost is marked estimated; a numeric provider-reported total remains
authoritative, and such usage gets no estimated breakdown, which would not add
up to it.

### Provider errors

Adapters return provider and transport failures as
`{:error, %Tackle.Lib.LLM.Error{}}`, with a `kind`, the HTTP `status`,
`retry_after_ms` from `Retry-After`, a `message` hosts may show, and the raw
failure in `details`. The loop decides retries, backoff, and overflow recovery
from these fields alone, so adapters share the classification instead of
matching provider wording themselves:

```elixir
alias Tackle.Lib.LLM.Error

# An HTTP error response: 429 → :rate_limited, 529 → :overloaded, a 400 whose
# error code or message names a context limit → :context_window_exceeded, ...
{:error, Error.from_response(response.status, response.body, response.headers)}

# A failed connection, such as %Req.TransportError{reason: :econnrefused}
{:error, Error.from_transport(reason)}

# An error the provider reports inside a stream after a 200
{:error, Error.from_stream(event["error"])}
```

Failures that are not provider failures, such as missing credentials, an
unsupported model, or cancellation (`:cancelled`), stay plain reasons and are
never retried.

Hosts may inject a `{module, reference}` credential-store handle in
`opts[:credential_store]`, which adapters read with
`Tackle.Lib.CredentialStore.from_opts/1`. Adapters access the provider's
namespace with `Tackle.Lib.CredentialStore.fetch/2` (which checks what the
store returns and reports its failures as `{:credential_store_failed,
reason}`), `put/3`, and `delete/2`, using
`Tackle.Lib.LLM.Provider.id(opts, adapter_id)` as the namespace so each provider
keeps its own login; `Tackle.Lib.LLM.Provider.settings(opts)` reads the
provider's settings (`%{}` when absent). Adapters that refresh credentials
should include the provider id in any refresh lock.

`Tackle.Lib.LLM.Provider` also holds the lookups adapters share:
`string_setting/3` reads a string setting, `put_base_url/2` applies the
`"base_url"` setting unless `:base_url` is explicit, and `api_key/3` finds an
API key in `opts[:api_key]`, the stored credentials (`"api_key"` or `"key"`),
or the environment variable the `"api_key_env"` setting names (or a default
variable for the adapter's default provider only), trimmed and checked to be
header-safe. Tackle.Lib treats
credential maps as opaque JSON-compatible data; OAuth flows, token schemas,
refresh logic, and persistence remain outside the library.

### Providers

`Tackle.Lib.LLM.Provider` is a configured instance of an adapter:
`%Provider{id: String.t(), adapter: module(), settings: map()}`. Several
providers may share one adapter, each with its own id, settings, and
credentials, such as two Codex subscriptions or a local and a remote server:

```elixir
alias Tackle.Lib.LLM.Provider

{:ok, work} = Provider.new("codex-work", MyApp.AI.CodexAdapter)
{:ok, home} = Provider.new("codex-home", MyApp.AI.CodexAdapter)

{:ok, gpu} =
  Provider.new("ollama-gpu", MyApp.AI.OllamaAdapter, %{"base_url" => "http://gpu:11434/v1"})

{:ok, llm} =
  Tackle.Lib.LLM.select([work, home, gpu, MyApp.AI.AnthropicAdapter], "codex-home/gpt-5.5")
```

- Provider ids are lowercase letters, digits, and inner hyphens, and must be
  unique across the expanded list; a duplicate returns
  `{:error, {:duplicate_provider_id, id}}` and an unknown prefix returns
  `{:error, {:unknown_provider, id}}`. A prefix never falls back to an adapter
  type id.
- Settings are an opaque, JSON-compatible map with string keys. Tackle.Lib
  never interprets them; each adapter documents the keys it honours.
- `Provider.defaults/1` returns an adapter's default providers and
  `Provider.expand/1` turns a mixed list of providers and adapter modules into
  providers. `Provider.opts/1` returns the `:provider_id` and
  `:provider_settings` adapter options for a provider.
- `Tackle.Lib.LLM.Selection` and `Tackle.Lib.Decision.Selection` carry
  `:adapter`, `:provider_id`, `:provider_settings`, `:model`, and `:ref`;
  `Tackle.Lib.LLM.Selection.provider/1` rebuilds the `%Provider{}`. Responses
  and normalized usage report the provider id as `:provider`.

Breaking changes from adapter-keyed selection: `{:unknown_adapter, id}` is now
`{:unknown_provider, id}`, `{:duplicate_adapter_id, id}` is now
`{:duplicate_provider_id, id}`, selections no longer carry `:adapter_id`, and
the `:provider_options` adapter option (settings keyed by adapter id) is
removed; adapters read their own provider's `opts[:provider_settings]`
instead. `{:unsupported_decision_adapter, provider_id}` and
`{:invalid_local_flag, provider_id, value}` keep their names but now carry the
provider id.

### Account flows

The optional `login/1`, `logout/1`, `status/1`, and `usage/1` callbacks let an
adapter own its complete account lifecycle so a frontend never hard-codes
provider knowledge:

- `login/1` runs the interactive flow (device code, browser hand-off, API-key
  prompt) and returns credentials to store. The host passes a
  `Tackle.Lib.Interaction` handle in `opts[:interaction]`; the adapter calls
  `info/2`, `prompt/2`, and `progress/3` on it instead of depending
  on a terminal library.
- `logout/1` revokes or removes credentials. When omitted, the host deletes the
  credentials stored under the provider id.
- `status/1` reports credential state. When omitted, the host reads the
  credential store and returns `{:ok, :stored} | {:ok, :missing}`.
- `usage/1` returns a host-renderable map (plan, balance, rate-limit windows).
  Adapters with no account endpoint omit it.

The host resolves the provider, injects `:interaction`, `:credential_store`,
`:provider_id`, `:provider_settings`, and any supplied options, and stores the
map returned by `login/1` under the provider id. Example:

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

An adapter implements `generate/2`, `stream/3`, or both. Without `stream/3`,
a streaming caller gets `generate/2` and one normalized usage event; without
`generate/2`, a non-streaming caller gets `stream/3` with a callback that drops
the events. Selection requires at least one of them.

The loop supplies these adapter options:

- `:model`, `:provider_id`, `:provider_settings`
- `:session_id` — stable across the conversation for provider cache affinity
- `:system`
- `:messages` — the sole conversation transport
- `:temperature` — `0.3` unless host options set it
- `:tools` — provider-neutral definitions, in the order of the state's `:tools`
- `:cancellation_signal`, when present
- host `state.llm_opts`, except unsupported tool-policy options

Other callers add `:tool_choice` (`"none"`) and `:max_tokens`. The
`Tackle.Lib.LLM` module docs list every standard option; callers build them
with `Tackle.Lib.LLM.request_opts/3`, so host options never replace the keys
that define a request.

`schema` is `nil` for a chat turn. Callers may pass a keyword or JSON Schema
map for a structured response; the library converts it once, and the adapter
always receives a JSON Schema map with string keys.

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
   provider_state: %{"opaque" => "..."}
 }}
```

`:usage` is canonical: a `%Tackle.Lib.Usage{}`, a map with its field names (atom
or string keys), or `nil`. Adapters translate their provider's report
themselves, usually with `Tackle.Lib.Usage.new/1`, which takes the disjoint
buckets (`:input_tokens` uncached, `:cache_read_tokens`, `:cache_write_tokens`)
or derives the uncached input from an OpenAI-style `:prompt_tokens` count that
includes cached tokens, and keeps the provider's report in `:raw`. Tackle.Lib
does not guess at provider field names such as `prompt_tokens` or
`cached_tokens`. Adapter price cards may fill an itemized and total estimate
when the provider omits cost; hosts still own billing, quota, and persistence
policy.

`Tackle.Lib.LLM.generate_with/3` and `stream_with/4` check the result and
return `{:ok, %Tackle.Lib.LLM.Response{}}`
(`Tackle.Lib.LLM.Response.from_result/1`), which the loop, hooks, events, and
messages use. `"content"` and `"thinking"` (or `:content` and `:thinking`) must
be strings or absent, `"tool_calls"` (or `:tool_calls`) a list of calls
`Tackle.Lib.Tool.Call.normalize/1` accepts or absent, and `:provider_state` a
map or `nil`. The response keeps the result's `:data` map, where structured
callers read the parsed object. Any other result, and an adapter return that
is not `{:ok, _}` or `{:error, _}`, is
`{:error, %Tackle.Lib.LLM.Error{kind: :invalid_response}}`, and an adapter that
raises, throws, or exits is `{:error, %Tackle.Lib.LLM.Error{kind: :unknown}}`;
either ends the turn instead of crashing the loop. The response's `:provider`
is the selected provider id, whatever the adapter reports.

`:provider_state` is optional opaque, non-secret continuation metadata needed by
some stateless provider APIs. The library stamps it with the `"provider"` id
and the requested `"model"`, Tackle.Lib stores it on the assistant message, and
the library passes it back in later `opts[:messages]` only to the same provider
and model: it drops every other message's provider state before calling the
adapter. State from one account is therefore never replayed to another
provider on the same adapter, and adapters do not check its origin. Hosts that
persist conversations must preserve this field.

Provider adapters are also responsible for putting Tackle.Lib's tool
definitions (`Tackle.Lib.Tool.definition/1`) into the provider wire format.
Each definition in `opts[:tools]` carries its parameters as a JSON Schema
object in `:input_schema`, computed once by the library with
`Tackle.Lib.Tool.Schema.JsonSchema.to_json_schema/1`, so adapters send it as it
is instead of converting schemas themselves. Structured-output schemas are
converted by the library the same way before the adapter sees them.

### Decision models

`Tackle.Lib.Decision` is an optional contract for small decision models that
answer typed questions about a state instead of chatting. An adapter may
implement it next to `Tackle.Lib.LLM` (it still needs `adapter_id/0`):

```elixir
@callback decision_models() :: [String.t()]
@callback decision_models(settings :: map()) :: [String.t()]  # optional, preferred
@callback decide(Tackle.Lib.Decision.Request.t(), opts :: keyword()) ::
            {:ok, Tackle.Lib.Decision.Result.t()} | {:error, term()}
```

```elixir
alias Tackle.Lib.Decision
alias Tackle.Lib.Decision.Question

{:ok, selection} = Decision.select(adapters, "ollama/tev1:4b")

question =
  Question.choice("verdict", "Is this command stuck?", %{
    "progressing" => "Output is still advancing",
    "infinite_loop" => "The same output repeats forever",
    "stalled" => nil
  })

{:ok, %Decision.Result{answers: %{"verdict" => answer}}} =
  Decision.ask(selection, %{"command" => "make test"}, [question],
    receive_timeout: 10_000
  )
```

`ask/4` builds the `Tackle.Lib.Decision.Request` and calls `decide/3`, which
takes a prebuilt request.

Questions are `:choice` (option => description or `nil`, 2–24 options),
`:noul` (yes/no with the probability of `true`; optional `"true"`/`"false"`
descriptions), or `:score` (2–24 level descriptions, lowest first). Requests are
validated before an adapter is called: 1–64 uniquely named questions, a
non-empty binary/map/list state, and at most 64 KiB once encoded with
`Tackle.Lib.Decision.Request.to_json_map/1`. `select/2` accepts providers and
adapter modules and parses `provider_id/model` references like
`Tackle.Lib.LLM.select/2`. It accepts providers without decision support in the
list, and reports `{:unsupported_decision_adapter, provider_id}`,
`{:unknown_provider, provider_id}`, or `{:unknown_decision_model, ref}`
explicitly. Adapters receive `:cancellation_signal`, `:receive_timeout`,
`:provider_id`, and `:provider_settings` in opts; the library itself performs
no HTTP.

`decide/3` is a boundary like `Tackle.Lib.LLM.generate_with/3` and never
raises. Every result is checked against the request's questions: exactly one
`Tackle.Lib.Decision.Answer` per question, of the question's type, with a
`choice` among its options, a `noul` probability in `0..1`, a `score` within
the scale (`0` to the number of levels minus one; fractional when an adapter
reports the probability-weighted average of the levels), probabilities and
confidence in `0..1`, and usage that is a map or `nil`. A result that does not
fit returns `{:error, %Tackle.Lib.LLM.Error{kind: :invalid_response}}` with
the `:reason` and the spent `:usage` in its details, and an adapter that
raises, throws, or exits returns `{:error, %Tackle.Lib.LLM.Error{kind:
:unknown}}`. Adapters therefore translate their wire format and leave these
checks, and request validation, to the library.

An adapter whose decision models run on hardware the user controls (such as a
self-hosted Ollama server) may also export the optional `local?/1` (given the
provider's settings, preferred) or `local?/0` callback returning `true`. Its
selections then carry `local: true`, so hosts can leave their usage out of
token budgets that bound paid spend; adapters without either callback are
treated as remote. A non-boolean answer returns
`{:error, {:invalid_local_flag, provider_id, value}}`.

## Tool system

### Behaviour and DSL

A manual tool implements:

- `name/0`
- `description/0`
- `parameters_schema/0`
- `execute/2`
- optional `output_schema/0`
- optional `effect/0`

`use Tackle.Lib.Tool` imports the DSL macros of `Tackle.Lib.Tool.DSL`
(`tool_name`, `description`, `input`, `output`, `field`), generates the
standard callbacks from them, and delegates execution to `run/2`. `Tackle.Lib.Tool.tool?/1` checks that a module is loadable
and exports the four required callbacks; `Tackle.Lib.Tool.missing_callbacks/1`
lists the ones it lacks.

Supported schema types are:

- `:string`
- `:integer`
- `:float`
- `:boolean`
- `:map`
- `{:list, inner_type}`

Field options are `:type`, `:required`, `:default`, `:description`, `:enum`,
and `:nullable`. `Tackle.Lib.Tool.Schema.validate_schema/1` checks a schema;
the DSL runs it when a tool compiles and `Tackle.Lib.Tool.Registry.new/1` when
a tool is registered, so an unknown type or option raises `ArgumentError`
instead of being accepted silently.

Integer, float, and boolean strings are coerced where unambiguous; `:float`
fields always return floats (`1` becomes `1.0`), and `:string` fields accept
numbers and booleans as their string form but reject lists and maps. `:map`
fields (including the items of `{:list, :map}`) accept a JSON object string,
which some providers send for nested objects. `""` is a value of a `:string`
field (so a tool can write an empty file); on every other type it counts as
absent, like `nil`. Absent fields get their default. `nullable: true` accepts
and preserves an explicit `nil` (JSON `null`); an enum on such a field must
include `nil` to allow it. Enum membership is checked with `in` after
coercion, so `1` and `1.0` differ. A tool's definition advertises nullable
fields with a `[type, "null"]` JSON Schema type. Tackle.Lib
never creates atoms from provider/user keys.

### Settlement and errors

`Tackle.Lib.Tool.settle/3` is the canonical local execution pipeline:

1. settle a call whose provider arguments were not a JSON object
   (`Tackle.Lib.Tool.Call`'s `argument_error`) as an `:invalid_input` error,
   without running the tool;
2. validate and coerce arguments;
3. execute the host tool;
4. validate output when a schema exists (a keyword output schema requires a
   map; a `{validator, schema}` tuple calls the host validator module; a map,
   such as an MCP tool's JSON Schema, is opaque and not validated);
5. preserve the raw result for host events;
6. project the result to text/JSON for the model transcript, replacing
   invalid UTF-8 with U+FFFD.

A tool that also produces non-text content returns `%Tackle.Lib.Tool.Content{}`
from `execute/2`. Settlement then keeps its text projection as the transcript's
string `content` (what human-facing surfaces and token estimates read) and
carries its extra parts — currently images — on
`Tackle.Lib.Tool.Result.parts` and the linked message's `parts`. `to_provider/1`
turns those into a provider-neutral content-part array that adapters lower into
their wire format; text-only adapters degrade the parts explicitly.

Do not bypass settlement in custom runtimes. It is what keeps agent and MCP
execution consistent.

Expected tool failures return `{:error, reason}`. A binary `reason` is the
model-facing message: the linked tool result reads `"Error: " <> reason`, so the
agent can react to failures such as a missing file, a non-zero command, or a
rejected delegation. Write these messages for the model and never put secrets
in them. Any other reason gets a generic model-facing text, and the reason
stays in the error's `message` and `details` (and the `:tool_error` event) for
the host. Argument validation errors are shown to the model (for example
`"Error: Invalid tool arguments: path: is required"`); they name only schema
fields and limits. Exceptions, exits, and throws are caught and logged as bugs
and settle like a crash (`Tackle.Lib.Tool.Error.crashed/3`: the message reads
`"Tool crashed: ..."` and `details` is `{kind, reason}`); their model text is
generic, and they should not be normal control flow. `Tackle.Lib.Tool.Error`'s
constructors (`unknown_tool/1`, `invalid_input/2`, `invalid_output/2`,
`failed/2`, `crashed/3`, `interrupted/3`) build every tool error.

A provider tool call whose arguments are not valid JSON or not an object is
kept with its id and name, and `Tackle.Lib.Tool.Call.normalize/1` marks it
with `argument_error` (empty arguments, including `""`, are `%{}`). The call
settles as an `:invalid_input` error the model can see and retry, without
running the tool or passing the `:before_tool_execution` gate, instead of
failing the whole turn.

Calls to unknown tools settle as typed `:unknown_tool` errors.
`Tackle.Lib.Tool.Registry.new/1` raises `ArgumentError` for invalid tool
modules, invalid names, or duplicate names; registration never silently drops
tools or selects one duplicate over another. Tool sets have deterministic
SHA-256-derived IDs (`Tackle.Lib.Snapshot.tools_version_id/1`) for audit and
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
| Tool crash                             | becomes a tool error; later calls continue | becomes a tool error; siblings continue  |
| Cancellation                           | calls not yet started are skipped | in-flight tasks get a grace period, then are killed |
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
`Task.Supervisor`. A tool crash becomes a tool error result, and results are
still appended in call order. When the turn is cancelled, the tools see it
through their call's cancellation signal; the batch waits up to two seconds in
total for them to stop (so `bash` can kill its processes), keeps the results of
calls that settle, and kills the rest, whose calls get the usual interrupted
results. A task that cannot be started (the supervisor is down or at its
`:max_children`) settles as a crashed tool error, as do the calls after it.
Tool tasks are not linked to the loop process, but they do not outlive it:
if it crashes or is killed, each running call is cancelled with reason
`:caller_down`, given the same grace, and then killed. The supervisor is
host-owned so one agent session cannot leak tasks into another; `run/3` and
`continue/2` raise `ArgumentError` before the turn starts if `:concurrent` is
configured without a `:tool_supervisor`.

Either mode may still select its tools up front. Tackle.Lib intentionally does
not support forced tool choice, provider-side parallel tool calls, allow/deny
options, or weighting. `Tackle.Lib.LLM.request_opts/3`, which builds the
adapter options of every loop and compaction request, removes these keys from
`llm_opts`:

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
to every tool. A tool's context also has the run's `:tool_context` merged in,
the run's event callback under `:event_callback`, and its call's id under
`:tool_call_id`. If a cancellation signal exists, the tool receives its call's
child signal (`Tackle.Lib.Cancellation.for_call/2`) under `:cancellation_signal`
as well. The `Tackle.Lib.Tool` moduledoc documents these keys; tools report
progress through the callback with `Tackle.Lib.Tool.progress/3`.

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
| `after_prompt/3` | After the step's LLM response, normalized into `%Tackle.Lib.LLM.Response{}` |
| `before_tool_call/3` | Before each normalized tool call; can veto it or update the context, not change it |
| `after_tool_call/3` | After each success/error settlement |
| `after_message/3` | After each finalized user/assistant/tool message |
| `before_turn_end/2` | After a final answer, before the turn completes |
| `after_turn/2` | Once during terminal cleanup |

Return `:ok` to observe, `{:ok, new_context}` to replace the context for later
steps, or `{:error, reason}` to abort the turn. Hooks run in configured order;
each receives the context returned by the previous hook. A hook sees the loop's
values but cannot replace them: the loop dispatches the tool call it passed to
`before_tool_call/3`, so a hook that rejects a call returns `{:error, reason}`,
which ends the turn before the call runs.

Every hook must be a module that exports at least one callback.
`Tackle.Lib.State.new/1`, and the snapshot each turn captures, raise
`ArgumentError` for any other entry (`Tackle.Lib.Hook.validate!/1`), so a
misspelled gate fails loudly instead of being skipped.

`before_turn_end/2` can also return `{:continue, messages}` or
`{:continue, messages, new_context}` to keep the turn going: each message (a
non-empty string) is appended as a user message, in hook order, and the model
answers again. Use it for checks that gate the end of a turn, such as compiling
the project and reporting new errors. It runs only after a final answer when no
incoming messages are queued, not for errors or cancellation. The loop bounds
repeated continuations only by `max_iterations`, which ends the turn with an
error, so a gate should count its rounds in the context, stop continuing after
a few, and reset the count in `after_turn/2`:

```elixir
defmodule MyApp.Hooks.CompileGate do
  @behaviour Tackle.Lib.Hook

  @max_rounds 2

  @impl true
  def before_turn_end(_state, context) do
    rounds = Map.get(context, :compile_gate_rounds, 0)

    case MyApp.Checks.new_compile_errors() do
      [] ->
        :ok

      _errors when rounds >= @max_rounds ->
        :ok

      errors ->
        message = "The compile gate found new errors:\n" <> Enum.join(errors, "\n")
        {:continue, [message], Map.put(context, :compile_gate_rounds, rounds + 1)}
    end
  end

  @impl true
  def after_turn(_state, context), do: {:ok, Map.delete(context, :compile_gate_rounds)}
end
```

When the run has a cancellation signal, hooks other than `after_turn/2` get it
in their context as `:cancellation_signal`, so a slow hook can check
`Tackle.Lib.Cancellation.cancelled?/1` and stop early; the loop does not keep
it in the state's context.

Good hook uses include audit logging, incremental persistence, correlation
metadata, and cleanup. Hosts can use `after_message/3` and `after_turn/2` for
idempotent message persistence and title generation.

Do not use hooks as a substitute for tool authorization. A hook can abort a
turn, but the tool remains the final security boundary for its operation.

## Events and streaming

Pass `event_callback: fn event -> ... end` to receive provider-independent
events. The library's own event types (`Tackle.Lib.Event.core_type/0`) are:

- `:turn_start`, `:turn_end`, `:turn_cancelled`
- `:step_start`, `:step_end`
- `:message_start`, `:message_delta`, `:message_end`
- `:tool_start`, `:tool_progress`, `:tool_execution_end`, `:tool_end`, `:tool_error`
- `:usage`, `:status_change`, `:error`
- `:retry_scheduled`, `:retry_start`, `:retry_end`
- `:compaction_start`, `:compaction_end`, `:compaction_retry`
- `:provider_event` for unrecognized provider data

Each core event has one constructor in `Tackle.Lib.Event` (for example
`Event.tool_start/2` from a `Tackle.Lib.Tool.Call`, `Event.tool_error/2` from a
`Tackle.Lib.Tool.Error`, `Event.retry_end/4`), so each type has one payload
shape: every key is always present, `nil` when it does not apply. The
`Tackle.Lib.Event` moduledoc lists the payloads.

Hosts and tools may emit events of their own types, any atom, with
`Event.new/3`: the harness's `:subagent_started`, `:subagent_progress`,
`:subagent_finished`, and `:workflow_progress`, for example. Host auxiliary
events such as `:narration` carry `auxiliary: true` in their data: they
describe an agent without being its progress, so hosts neither persist them
nor count them as activity.

Every event is `%Tackle.Lib.Event{type, id, parent_id, data, timestamp, metadata}`.
Streaming text, reasoning, tool-input, usage, and provider errors are normalized
through `Tackle.Lib.Event.normalize/2`. The loop stamps streamed message deltas with
the message ID minted at `:message_start`, allowing a UI to route concurrent
in-flight display state safely.

Reasoning and tool-input deltas are tagged in event data. A user-facing UI
should not append them to the visible answer bubble by default. The
`tackle_phoenix` event reducer follows this rule.

Host tools may emit transient `:tool_progress` events through the callback in
their execution context with `Tackle.Lib.Tool.progress(context, data)`, which
builds them with `Tackle.Lib.Event.tool_progress/3` and puts the call's
`tool_call_id` in `data`. Progress should also carry `name` and a bounded
`delta`; it is presentation data and is replaced by the canonical `:tool_end`
or `:tool_error` settlement. `Tackle.Lib.Tool.progress(context, type, data)`
reports a host event type the same way.

`:tool_execution_end` reports each completed execution as the loop collects its
worker result, without waiting for the rest of a concurrent batch. It carries
`tool_call_id`, `name`, `status` (`:completed` or `:failed`), `result` (on
success), and `error`/`reason` (on failure). Sequential execution emits it too.
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
exponential delays of about 2, 4, and 8 seconds (capped at 60 seconds), each
drawn from the upper half of its backoff ("equal jitter") so agents that fail
together do not retry in lockstep. Configure it per state:

```elixir
Tackle.Lib.new(
  retry: [max_retries: 3, base_delay_ms: 2_000, max_delay_ms: 60_000, jitter?: true]
)
```

Use `retry: false` or `max_retries: 0` to disable retries, and `jitter?: false`
for exact delays. Adapters report provider and transport failures as
`%Tackle.Lib.LLM.Error{}`, and the retry decision is made from its `kind` alone
(`Tackle.Lib.Retry.retryable?/1`): `:transport`, `:timeout`, `:rate_limited`,
`:overloaded`, and `:server` are retried; `:context_window_exceeded`,
`:quota_exceeded`, `:auth`, `:invalid_request`, `:invalid_response`, and
`:unknown` are not, and neither is any reason that is not a
`Tackle.Lib.LLM.Error`, such as cancellation or a missing credential. When the
provider sent `Retry-After` (or `retry-after-ms`), the error's `retry_after_ms`
makes the wait at least that long, still capped at `max_delay_ms`. Context
overflow is classified first and retains its compact-and-retry path. A
`:before_provider_call` gate refusal is host policy and ends the request without
a retry; hooks, tools, compaction commits, and other persistence also remain
outside this policy. The backoff wait cooperatively polls the turn's
cancellation signal.

A retry reuses the same provider messages, pending assistant message ID, and
loop iteration. It does not append a second user message. Hosts rendering
streaming deltas should clear output for the pending assistant ID when they
receive `:retry_scheduled`, before the next attempt emits more deltas.

Retry lifecycle data includes the one-indexed `attempt`; `:retry_scheduled` also
includes `max_retries`, `delay_ms`, and `reason`, while the single terminal
`:retry_end` includes `success?` and the final `reason` (`nil` on success). All
three carry the pending assistant message ID as the event `id`.

A response with neither content nor tool calls is asked again once, as a retry
of the same request: `:retry_scheduled` with reason `:empty_response`
(`attempt: 1`, `max_retries: 1`, `delay_ms: 0`), then `:retry_start`. The re-ask
is numbered on its own and neither uses nor resets the transient retry budget.
A second empty response
in a row ends the turn with "The model returned an empty response" and the
error reason `:empty_response`. Every response, including an empty one, emits
its own `:usage` event, but a step emits a single `:step_end`, for the response
it keeps, and the `after_prompt` hooks only see that response.

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
calls. It also rechecks after `:before_provider_call` and `before_tool_call` hooks,
before provider or tool dispatch. The optional `before_provider_call: fn -> ... end`
run option is called immediately before every `generate/2` or `stream/3` invocation,
including automatic retries, and before each compaction summarizer invocation;
return `:ok` to proceed or `{:error, reason}` to skip that dispatch. Standalone
`Tackle.Lib.Compaction.compact/3` accepts the same gate option. A host can use
this gate for provider-call readiness without adding storage policy to Tackle.Lib.
The adapter receives the cancellation signal in its opts and tools receive it
in context. Long-running adapters and tools should check
`Tackle.Lib.Cancellation.cancelled?/1` and abort their own work.

Each tool's `:cancellation_signal` is a per-call child of the turn signal,
derived with `Tackle.Lib.Cancellation.for_call(turn_signal, tool_call_id)`. A
child reports its own reason first and otherwise its parent's, so cancelling the
turn still stops every call, while a host (for example a watchdog) can cancel
one child to stop only that call; the tool returns an error and the turn
continues. Child ids are the deterministic `{parent_id, tool_call_id}`, so the
host derives the same child from the turn signal it already holds. The loop
deletes each child record after its call settles, and deleting the turn signal
deletes any child a host cancelled after its call settled.

Cancellation is cooperative, not preemptive. Tackle.Lib cannot interrupt code that
ignores the signal. The first cancellation wins: cancelling a cancelled signal
keeps its original reason, and a `nil` reason is stored as `:cancelled`. Delete
signals after terminal settlement with `Tackle.Lib.Cancellation.delete/1`, which
also deletes every per-call signal derived from the signal;
`Tackle.Phoenix.Runner` manages this lifecycle automatically.

The cancellation store is configurable:

```elixir
config :tackle_lib, cancellation_store: MyApp.CancellationStore
```

It defaults to an ETS-backed implementation that supports cross-process access
on one BEAM node. A supervised process in the `:tackle_lib` application owns the
table, so cancellation records survive the exit of tasks that read or write them.
Ensure the application is started before using the default store (Mix normally
starts dependency applications; standalone scripts can use
`Application.ensure_all_started(:tackle_lib)`). Operations raise `ArgumentError`
if the table is unavailable; they never create a replacement in the caller.
Records are not durable across store owner or application restarts. Every host
on the node shares this table; the Tackle runtime uses it too. Custom stores
remain host-owned: the host is responsible for starting and supervising them,
and they must keep the first reason and delete derived per-call records (see
`Tackle.Lib.Cancellation.Store`).
Store ids are references for turn signals and `{parent_id, tool_call_id}` tuples
for per-call signals, so custom stores must accept any such term as a key.

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
`tools_version_id` values. `tools_version_id` hashes the tool definitions in
registration order, the order providers receive them, and is the same for a
list of tool modules and a registry built from it. Persist those IDs in host
audit records when you need to explain which configuration a turn used. The
snapshot belongs to the running turn and is not stored on `Tackle.Lib.State`;
`continue/2` captures a fresh one like `run/3`.

## Prompt caching

The loop sends the stable state `:session_id` to every adapter so providers
with cache-affinity keys can reuse the same cache route across steps and
turns, and it never injects synthetic per-step messages, so each request
extends the previous one's prefix. Provider-specific cache markers belong in
the adapter.

## Context compaction

`Tackle.Lib.Compaction` replaces the **provider-visible projection** when a long
session approaches the model's context window. It never touches the canonical
transcript: `State.messages` stays complete, while `State.model_messages` becomes a
synthetic checkpoint plus a recent structurally valid tail. The planner walks
backward toward the retention target and may split an oversized turn at an
assistant boundary rather than keeping that entire turn; it never cuts while a
tool call still waits for its result, and never keeps verbatim a message too
large to fit below the threshold after compaction (such a message is shadowed
and summarized). Retained content and tool linkage stay intact, while stale
usage and provider continuation metadata are cleared at the new context
boundary.

Compaction is opt-in. Supply a config (or its options) when building state;
`compaction: nil`, the default, is the one way to disable it:

```elixir
state =
  Tackle.Lib.new(
    llm: selection,
    committer: MyApp.Committer,
    compaction: [
      summarizer: Tackle.Lib.Compaction.Summarizer.LLM,
      policy: [safety_reserve: 4_096, retain_ratio: 0.16]
    ]
  )
```

Entry points share one transaction:

- automatic `:pressure` compaction before every provider generation, at the
  model's resolved threshold;
- one `:overflow` compact-and-retry after a provider
  `%Tackle.Lib.LLM.Error{kind: :context_window_exceeded}`, whether the provider
  reported it in an HTTP error or inside a stream; and
- `Tackle.Lib.compact/2` for an idle, operator-requested compaction. A
  conversation that already fits the retention target has nothing to compact
  (`{:error, :nothing_to_compact, state}`).

Every entry point gets one of three results from
`Tackle.Lib.Compaction.compact/3`: `{:ok, state, record}`, or
`{:error, reason, state}` / `{:cancelled, reason, state}`, where `state` is
always the last committed state (the input when nothing was committed).
`Tackle.Lib.Compaction.nothing_to_do?/1` tells the reasons that only mean
there was nothing to do (`:disabled`, `:no_context_window`,
`:nothing_to_compact`) from failures; the loop calls `compact/3` with
`:pressure` before every request and goes on when there is nothing to do.

`Tackle.Lib.Compaction.Policy` resolves the threshold from the model's window,
a response reserve (the request's `:max_tokens` when the host sets one,
otherwise the model's output limit capped at 32,768 tokens, so a model that
declares half its window as output does not compact at half the window), and a
safety reserve. `summary_max_tokens` (8,192 by default) is the most output a
summary may ask for, lowered to the model's output limit. It keeps the retention target below what a compaction can leave
under the threshold once the system prompt, tools, and a summary are paid for,
and disables pressure compaction for windows too small for that.

A pass must make progress or fails before anything is committed: it shadows
more than an earlier checkpoint, its summary is complete and smaller than what
it replaces, and a pressure compaction ends below the threshold
(`:insufficient_reduction` otherwise). A pressure compaction that fails is not
retried for the rest of the turn; overflow recovery still applies. When the
shadowed messages would not fit the summarization request, the largest are
shortened with a marker (`Tackle.Lib.Compaction.Input`); the earlier checkpoint
is sent once, unshortened, as the first shadowed message. A checkpoint is known
by its compaction entry in the state's tree (`Tackle.Lib.State.last_compaction/1`),
never by its text, so a user message that reads like one is still a user
message.

A `Tackle.Lib.Compaction.Summarizer` only turns a request into text plus usage.
It receives the host-supplied `llm_opts` (including credential-store handles)
of the turn's snapshot, or of the state outside a turn, and the optional
`:cancellation_signal`; explicit compaction `:llm_opts` are merged on top. Summarizers should forward the signal to blocking provider
calls and check it cooperatively. A result other than `{:ok, %Summary{}}` or
`{:error, reason}`, and a summarizer that raises, throws, or exits, fails the
pass. The default `Tackle.Lib.Compaction.Summarizer.LLM` asks for the policy's
summary output limit and the `"minimal"` thinking level, and passes the
response's `stop_reason` on: a summary that stopped at `:max_tokens` is
rejected as truncated, and without a stop reason only visible output tokens
(output less reasoning) count toward the limit. If a later tightening pass
fails after an earlier pass has already committed, the returned state holds
that pass; retain it so the in-memory projection matches the durable
checkpoint. The core owns balanced cut selection, strict validation
(non-empty, complete, no tool calls, strictly smaller than the shadowed
region), the durability commit, and the in-memory replacement.
`Tackle.Lib.Compaction.Checkpoint` builds the checkpoint message, returns a
record's summary text (`summary/1`), and applies a committed
`Tackle.Lib.Compaction.Record` to a message list, for the live replacement and
for a tree's branches alike.

The state's `:committer`, a `Tackle.Lib.Committer`, makes the record durable
before replacement; a commit failure is reported as
`{:error, {:durable_commit_failed, reason}, state}` so a host can fail closed.
The same committer receives tree navigations (below), with the context
`%{session_id: session_id, context: context}`. A record names the tree entry
it attaches to in `:parent_id`, so a committer never needs the tree. A committer that returns anything but `:ok` or
`{:error, reason}`, raises, throws, or exits fails the commit the same way.

Lifecycle events `:compaction_start`, `:compaction_end`, and `:compaction_retry`
carry trigger, before/after estimates, counts, duration, and summary model/usage.
They never include raw prompts or summary content. `ContextUsage` reads the model
projection and estimates what requests send (reasoning text is not sent;
continuation state is), and retained assistant usage is stripped from it because
it no longer describes the current request. Treat compaction as the start of a new prompt-cache
reuse sequence.

## Conversation trees

Every `Tackle.Lib.State` keeps its conversation in a `Tackle.Lib.Tree`, a pure
value that needs no process, storage, or OTP supervision. A conversation that
never navigates is a tree with one branch; navigating lets it hold alternative
paths:

```elixir
state = Tackle.Lib.new(llm: selection, committer: MyApp.Committer)
{:ok, state} = Tackle.Lib.run(state, "investigate the cache")

# Move to the parent of an earlier user message; the selected message comes back
# as a draft so the host can refill its editor and create a sibling branch.
{:ok, state, outcome} = Tackle.Lib.navigate(state, {:edit, user_message_id})
outcome.draft.content
outcome.change.to_id # the parent, now the active position

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
archive while `Tackle.Lib.State.branch_usage/1` follows the active path, and
`Tackle.Lib.context_usage/1` measures the selected model projection. A compaction
on one branch never changes a sibling's context, and returning after a
compaction restores the same summary without re-summarizing.

Navigation never runs a turn, re-executes a tool, or edits entries. It validates
the destination against the current revision, rejects a structurally incomplete
tool batch with `{:error, {:unsafe_continuation, id}}`, and commits its
`Tackle.Lib.Tree.Change` through the state's `Tackle.Lib.Committer` before
installing the position (`Tackle.Lib.Tree.Navigator`). The committer is always
the state's own, never an option, so a caller cannot skip the commit; the only
option is `:expected_revision`, and any other raises `ArgumentError`. A missing
committer is valid only for explicitly in-memory use. Failed validation or
commit leaves the accepted state unchanged. The outcome
(`Tackle.Lib.Tree.Navigator.Outcome`) wraps the change with the edit draft
and whether the navigation was a no-op, which commits nothing. Hosts that
persist their own entries rebuild a tree by appending them in order with
`Tackle.Lib.Tree.append_message/3` and `append_compaction/3` and their
`:parent_id`, which validate every link, and `Tackle.Lib.Tree.move/2` to the
recorded position, then pass the tree to `Tackle.Lib.new/1` (`:tree`) or
`Tackle.Lib.State.put_tree/2`.

A tree keeps an index of each entry's children, so `Tackle.Lib.Tree.children/2`
costs the number of children. `Tackle.Lib.Tree.resumable?/2` checks one entry;
`Tackle.Lib.Tree.resumable_ids/1` returns every safe continuation point in one
walk, for views that render the whole tree.

`State.messages` and `State.model_messages` are cached derivations of the
tree. `Tackle.Lib.State.add_message/2` extends them, `put_tree/2` installs a
tree and re-derives both, and `update_message/3` replaces one settled message
(to attach usage reported after the turn, say); never write the fields
directly. Whether users may branch is host policy: the library can always
navigate, and a host that does not offer branching simply never calls
`navigate/3`.

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
rate. `cache_reuse_rate/1` returns only that ratio. A sequence must not span a
compaction or another non-append-only context rewrite; both also take a list of
sequences, measured separately and summed, such as
`Tackle.Lib.State.usage_segments/1`, which splits a conversation's usage at its
compactions.

The metrics return `nil` when their required cache reporting or prompt usage is
unavailable. `Tackle.Lib.usage(state)` derives aggregate usage from assistant
messages so a separate mutable total cannot drift. Cost aggregation is
conservative: costs are summed only when every entry has numeric cost and
currencies are compatible; an aggregate containing any estimate is itself
estimated.

`Tackle.Lib.context_usage(state)` uses the latest non-zero assistant usage as a
checkpoint, preferring provider `total_tokens` and otherwise summing input,
output, cache-read, and cache-write exactly once. Messages after that checkpoint
are estimated at four UTF-8 characters per token, and image parts at a fixed
1,600 tokens each. With no checkpoint, the system prompt, messages, and
provider-neutral tool definitions are estimated.
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

The events follow the `:telemetry.span/3` conventions (see
`Tackle.Lib.Telemetry`): `:start` measures `system_time` and `monotonic_time`,
`:stop` and `:exception` measure `duration` and `count`, and every event's
metadata carries the start metadata (`tool_name`) and a `telemetry_ref` that
correlates them. `:stop` adds the bounded `outcome`; `:exception` (a call
whose preparation or settlement crashed) adds `kind` (`:error`, `:exit`, or
`:throw`) but never the raw reason or stacktrace.

Metadata is deliberately bounded. Tool names are reported only when the host
places the allowed names under `state.context.telemetry.tool_names`; other names
become `"other"`. Do not put prompts, tool arguments, results, or raw errors in
telemetry metadata.

`Tackle.Phoenix.Runner` additionally emits turn telemetry; see the Phoenix
README.

## JSON

Tackle.Lib encodes and decodes JSON with Elixir's built-in `JSON` module; it
has no JSON adapter setting and no JSON dependency.

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

An assistant message's tool calls are always `Tackle.Lib.Tool.Call` structs (and
`[]` without calls); `Tackle.Lib.Message.assistant/1` normalizes stored call
maps with string or atom keys through `Tackle.Lib.Tool.Call.normalize/1` and
raises `ArgumentError` on a call that does not normalize. Store at least each
call's `id`, `name`, and `arguments`.

A turn that stopped mid-batch can leave calls without results, which providers
reject. `Tackle.Lib.Loop.run/3` and `continue/2` settle them with synthetic
error results when the next turn starts; a host that wants the history repaired
before then (for display, or to persist the repair on its own) builds the same
results with `Tackle.Lib.Messages.interrupted_results/3`.

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
| Model selection | `lib/my_app/agent/agent.ex` | Select `provider/model` with `Tackle.Lib.LLM.select/2` per state |
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
- built-in parent/child orchestration (use the optional `tackle_runtime` package); or
- a complete chat UI.

`Tackle.Phoenix.Chat` is currently a documented scaffold, not a working LiveView
mixin. Use `Tackle.Phoenix.EventReducer` directly as shown in the Phoenix README.

## Performance benchmarks

Repository-only Benchee suites cover history growth, context estimation, and
tool settlement with and without output validation. See the [benchmark guide](../../bench/README.md)
for commands, smoke checks, saved baselines, and measurement limitations.
Benchee is dev-only and is not a runtime dependency.

## Source guide

Start with these files:

- `lib/tackle_lib.ex` — public facade
- `lib/tackle_lib/loop.ex` — authoritative lifecycle
- `lib/tackle_lib/state.ex` and `lib/tackle_lib/message.ex` — in-memory model
- `lib/tackle_lib/usage.ex`, `model_info.ex`, and `context_usage.ex` — session statistics
- `lib/tackle_lib/llm.ex` — provider contract
- `lib/tackle_lib/llm/provider.ex` — configured adapter instances
- `lib/tackle_lib/decision.ex` — optional decision-model contract
- `lib/tackle_lib/tool.ex` and `lib/tackle_lib/tool/schema.ex` — tool contract
- `lib/tackle_lib/hook.ex` and `lib/tackle_lib/event.ex` — extension/streaming seams
- `lib/tackle_lib/cancellation.ex` — cooperative cancellation
- `lib/tackle_lib/snapshot.ex` — per-turn configuration stability
- `lib/tackle_lib/integrations/registry.ex` — registry for host-owned tool bridges
