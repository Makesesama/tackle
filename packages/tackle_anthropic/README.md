# Tackle Anthropic

First-party Anthropic Claude provider plugin for Tackle.

`Tackle.Plugins.Anthropic` implements the same `Tackle.Lib.LLM` behaviour used by
third-party adapters. It translates provider-neutral messages, native tools,
structured response schemas, streaming deltas, and usage into the Anthropic
Messages API, and supports both Claude Pro/Max OAuth and API-key auth.

The plugin depends on `:tackle_lib`, not the root `:tackle` harness. A host owns
credential persistence and frontend interaction.

## Authentication

### Claude Pro/Max OAuth

Claude subscription access requires the Claude Code client shape. When OAuth
credentials are used, the adapter sends the Claude Code billing-header and
identity system blocks, the Claude Code betas, and the Claude Code user agent,
and namespaces non-Claude-Code tools like MCP tools (`mcp__tackle__<name>`).
This mirrors the `pi-anthropic-oauth` extension.

OAuth interaction is separate from model requests: `generate/2` and `stream/3`
never prompt or open a browser.

```elixir
alias Tackle.Plugins.Anthropic
alias Tackle.Plugins.Anthropic.OAuth

{:ok, flow} = OAuth.begin_authorization()
IO.puts("Open #{flow.url}")

# Ask the user to paste the final callback URL or the code#state value.
{:ok, credentials} = OAuth.exchange_callback(flow, pasted)
:ok = Tackle.Auth.put(Anthropic.adapter_id(), credentials)
```

The default redirect URI is `https://platform.claude.com/oauth/code/callback`,
so no local web server is required. The frontend must preserve and return the
exact `flow` map until exchange so state and PKCE verification remain linked.

The advertised Claude Code version defaults to `2.1.280`; override it with the
`:claude_code_version` option or `TACKLE_ANTHROPIC_CLAUDE_CODE_VERSION` when
Anthropic requires a newer client. System-prompt rewriting can be tuned with
`TACKLE_ANTHROPIC_REWRITE_MODE` / `TACKLE_ANTHROPIC_REWRITE_PATTERN`.

Credentials contain access and rotating refresh tokens. The adapter refreshes
expiring credentials before requests, persists rotated tokens through the
injected `Tackle.Lib.CredentialStore`, and retries one request after a `401`.

### API key

Pass `api_key: "sk-ant-..."`, store one under the `"anthropic"` credential
namespace, or set `ANTHROPIC_API_KEY`. API-key requests use `x-api-key` and send
only the `interleaved-thinking-2025-05-14` beta.

```elixir
{:ok, credentials} = Anthropic.login(auth: :api_key, interaction: interaction)
```

## Using the adapter

```elixir
{:ok, session} =
  Tackle.start_session(
    adapters: [Tackle.Plugins.Anthropic],
    model: "anthropic/claude-opus-5-5",
    llm_stream: true,
    llm_opts: [reasoning_effort: "high"]
  )
```

`:reasoning_effort` accepts `minimal`, `low`, `medium`, `high`, and `xhigh`.
Adaptive-thinking models (`*-5`, `*-4-6` and later) send `thinking: adaptive`
plus an `output_config.effort`; older models send budgeted thinking, clamped to
`max_tokens - 1`. `:thinking_budgets` overrides the default per-level budgets.

`temperature` and `top_p` are omitted while thinking is enabled, matching the
API's constraint.

For stateless continuations, the adapter stores the assistant's raw content
blocks (including thinking signatures and redacted thinking) on the assistant
message's `provider_state` and replays them only for the same provider, model,
and auth mode. Hosts that persist conversations must preserve
`Tackle.Lib.Message.provider_state`.

Context-window overflow is classified only from errors that name a token/context
limit; generic 4xx/5xx and transport failures stay unclassified. Anthropic's
`max_tokens` stop reason is returned as a normal terminal response with the
partial content.

`model_info/1` exposes the selectable catalog's context windows, maximum output
limits, and USD-per-million-token price cards, including cache read/write rates.

## Development

```sh
mix deps.get
mix compile --warnings-as-errors
mix test
mix format --check-formatted 'mix.exs' 'lib/**/*.{ex,exs}' 'test/**/*.{ex,exs}'
```

Req `0.8.0-rc.0` is pinned because it uses Elixir's standard-library `JSON`
module. Req `0.7` has a mandatory Jason dependency, which Tackle does not permit.
