# Tackle Codex

First-party OpenAI Codex provider plugin for Tackle.

`Tackle.Plugins.Codex` implements the same `Tackle.Lib.LLM` behaviour used by
third-party adapters. It translates provider-neutral messages, native tools,
structured response schemas, streaming deltas, and usage into the ChatGPT Codex
Responses protocol.

The plugin depends on `:tackle_lib`, not the root `:tackle` harness. A host owns
credential persistence and frontend interaction.

## Authentication

The adapter uses ChatGPT subscription OAuth credentials stored in the
`"openai-codex"` credential namespace. OAuth interaction is separate from model
requests: `generate/2` and `stream/3` never prompt or open a browser.

### Device-code login

```elixir
alias Tackle.Plugins.Codex
alias Tackle.Plugins.Codex.OAuth

{:ok, device} = OAuth.request_device_code()

IO.puts("Open #{device.verification_uri}")
IO.puts("Enter #{device.user_code}")

{:ok, credentials} = OAuth.complete_device_code(device)
:ok = Tackle.Auth.put(Codex.adapter_id(), credentials)
```

`complete_device_code/2` polls until login completes, is cancelled, or reaches
the 15-minute deadline supplied by OpenAI.

### Browser authorization

The plugin prepares and validates the PKCE flow but intentionally does not own a
web server or browser UI:

```elixir
{:ok, flow} = OAuth.begin_authorization()
IO.puts("Open #{flow.url}")

# A frontend listens on flow.redirect_uri or asks the user to paste the final URL.
{:ok, credentials} = OAuth.exchange_callback(flow, callback_url)
:ok = Tackle.Auth.put(Codex.adapter_id(), credentials)
```

The default redirect URI is `http://localhost:1455/auth/callback`, matching the
Codex OAuth client's registered callback. The frontend must preserve and return
the exact `flow` map until exchange so state and PKCE verification remain linked.

Credentials contain access and rotating refresh tokens. The adapter refreshes
expiring credentials before requests, persists rotated tokens through the
injected `Tackle.Lib.CredentialStore`, and retries one request after a `401`.

## Using the adapter

When the plugin is available to the host distribution:

```elixir
{:ok, session} =
  Tackle.start_session(
    adapters: [Tackle.Plugins.Codex],
    model: "openai-codex/gpt-5.5",
    llm_stream: true,
    llm_opts: [reasoning_effort: "high", reasoning_summary: "auto"]
  )
```

The adapter maps `:reasoning_effort` and `:reasoning_summary` options to the
Responses API and emits provider-supplied reasoning summaries as normalized
reasoning deltas. It defaults to `transport: :auto`, which first tries a
session-scoped WebSocket and falls back to SSE if the WebSocket fails before any
response events arrive. Set `transport: :sse` to force HTTP streaming,
`:websocket` to reuse a connection while sending full context, or
`:websocket_cached` to require WebSocket continuation without automatic SSE
fallback.

With `:auto` and `:websocket_cached`, the adapter reuses the connection and sends
`previous_response_id` plus only newly appended input when the current request
extends the preceding request and all non-input request options still match. It
sends full context whenever that invariant does not hold and retries once with
full context if the provider no longer recognizes the previous response. Idle
connections close after five minutes by default; `:websocket_idle_timeout` and
`:websocket_connect_timeout` override the idle and connection timeouts. A host
that knows a session has ended can release its connection immediately with
`Tackle.Plugins.Codex.close_session(session_id)`.

For stateless SSE continuations and full-context WebSocket recovery, the adapter
stores the provider's opaque response output on the assistant message and replays
it only for the same provider and model. Hosts that persist conversations must
preserve `Tackle.Lib.Message.provider_state`.

For prompt caching, Tackle.Lib supplies its stable session ID on every model
request. The adapter uses it as `prompt_cache_key` and sends matching
`session-id`/`x-client-request-id` affinity headers. Codex cached-token usage is
normalized into the library's separate cache-read, cache-write, and uncached-input
buckets.

`model_info/1` exposes the explicit Codex catalog's context windows, maximum
output limits, and USD-per-million-token price cards. Tackle.Lib applies those
cards consistently to streaming and settled usage when the provider omits cost.
These totals are marked estimated. ChatGPT subscription usage does not necessarily
represent an API charge or invoice, so hosts must not treat the estimate as
provider-reported billing. Catalog values are maintained with the adapter and
should be reviewed whenever its selectable model list changes.

Zstd request compression and automatic model discovery remain out of scope.

## Development

```sh
mix deps.get
mix compile --warnings-as-errors
mix test
mix format --check-formatted 'mix.exs' 'lib/**/*.{ex,exs}' 'test/**/*.{ex,exs}'
```

Req `0.8.0-rc.0` is pinned because it uses Elixir's standard-library `JSON`
module. Req `0.7` has a mandatory Jason dependency, which Tackle does not permit.
