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

OAuth interaction is separate from model requests: `stream/3` never prompts or
opens a browser.

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

Pass `api_key: "sk-ant-..."`, store one under the provider's credential
namespace (`"anthropic"` for the default provider), or set `ANTHROPIC_API_KEY`
(default provider only; see [Providers](#providers)). API-key requests use `x-api-key` and send
only the `interleaved-thinking-2025-05-14` beta.

```elixir
{:ok, credentials} = Anthropic.login(auth: :api_key, interaction: interaction)
```

## Providers

`adapter_id/0` (`"anthropic"`) names the adapter type. Several providers can
share the adapter, each with its own login, for example a Claude subscription
and an API-key account selected as `claude-work/claude-opus-5-5` and
`claude-api/claude-opus-5-5`:

```elixir
alias Tackle.Lib.LLM.Provider

{:ok, work} = Provider.new("claude-work", Tackle.Plugins.Anthropic)
{:ok, api} = Provider.new("claude-api", Tackle.Plugins.Anthropic)
{:ok, selection} = Tackle.Lib.LLM.select([work, api], "claude-work/claude-opus-5-5")
```

The selection passes `:provider_id` and `:provider_settings` to the adapter, and
hosts pass the same options to `login/1` and `status/1`. Without them the
adapter acts as the default `"anthropic"` provider. The provider id is the
credential namespace read, refreshed, and written back; part of the OAuth
refresh lock, so accounts refresh independently. `Tackle.Lib.LLM` reports it
as the response's `:provider` and stamps it on replayable `provider_state`.
Only the default
`"anthropic"` provider falls back to `ANTHROPIC_API_KEY` when no credentials
are stored; other providers read an environment variable only when they name
one with `"api_key_env"`, so a key is never sent for another account by
accident. Without credentials, requests fail with
`{:error, {:missing_anthropic_credentials, provider_id}}`, and `status/1`
reports `{:ok, :missing}`.

Honoured provider settings:

| Key | Meaning |
| --- | --- |
| `"base_url"` | Messages API base URL. An explicit `:base_url` option wins. |
| `"api_key_env"` | Environment variable read for an API key when none is stored. Defaults to `ANTHROPIC_API_KEY` for the `"anthropic"` provider and to none otherwise. |

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
message's `provider_state`. `Tackle.Lib.LLM` passes them back only to the same
provider id and model, and the adapter replays them only for the same auth
mode. Hosts that persist conversations must preserve
`Tackle.Lib.Message.provider_state`.

Failures are `Tackle.Lib.LLM.Error`s: HTTP errors keep their status and
`Retry-After` (a `529` is `:overloaded`), stream `error` events such as
`overloaded_error` are classified by type, and a stream that ends before
`message_stop` is a `:transport` error. Context-window overflow is classified
only from errors that name a token/context limit. Anthropic's
`max_tokens` stop reason is returned as a normal terminal response with the
partial content.

Images in the conversation are fitted to Anthropic's per-request image limits
before each request, so a session that collected an oversized image keeps
working: images over 8000 px per side are always replaced with an explanatory
text block; once a request would carry more than 20 images, images over 2000 px
per side (or of unrecognised size) are replaced too; and beyond 100 images the
oldest are dropped. The replacement is deterministic, so it only disturbs the
prompt cache when a threshold is crossed, and the stored session keeps the
original images.

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
