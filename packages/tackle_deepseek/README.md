# Tackle DeepSeek

DeepSeek provider plugin for Tackle. The adapter uses DeepSeek's
OpenAI-compatible streaming Chat Completions API at
`https://api.deepseek.com`.

Advertised models:

- `deepseek-flash` (DeepSeek-V4.1-Flash)
- `deepseek-v4-flash`
- `deepseek-v4-flash-vision-exp`
- `deepseek-v4-pro`

The catalog follows deepseek-harness and Pi. All models have a 1,000,000-token
context window; `deepseek-flash` defaults to a 256,000-token maximum output,
while the V4 cards expose 384,000 tokens. DeepSeek's Chat Completions tool
results are text-only, so this plugin does not serialize image content parts: a
tool result carrying one sends an explicit `[image content omitted: ...]` note
instead of the image bytes.

## Usage

```elixir
{:ok, llm} =
  Tackle.Lib.LLM.select(
    [Tackle.Plugins.DeepSeek],
    "deepseek/deepseek-flash"
  )

state =
  Tackle.Lib.new(
    llm: llm,
    llm_opts: [api_key: System.fetch_env!("DEEPSEEK_API_KEY")]
  )
```

The API key is resolved in this order: `:api_key`, the provider's
credential-store namespace (`"api_key"` or `"key"`; `"deepseek"` for the
default provider), then an environment variable: the provider's
`"api_key_env"` setting, or `DEEPSEEK_API_KEY` for the default `"deepseek"`
provider only. A missing key is
`{:error, {:missing_deepseek_api_key, provider_id}}`. The bundled CLI populates the store
through the adapter's `login/1` with `tackle auth login deepseek` (during
development, `mix tackle auth login deepseek` from `apps/tackle_cli`), which
prompts for the key as secret input; depending on terminal support, the prompt
may be visible. Supplying it explicitly or through a host-owned
`Tackle.Lib.CredentialStore` is also supported.

The adapter translates structured Tackle messages, native tools, JSON response
schemas, and streamed text, reasoning, and tool-call deltas. A successful
stream must contain a recognized finish reason followed by `[DONE]`. Usage is
held until that terminal validation succeeds, and tool calls are returned only
after their identity and JSON-object arguments have been validated.

For reasoning controls, pass any `Tackle.Lib.Thinking` level as
`:reasoning_effort` in `:llm_opts` (`:none`/`:off` disables thinking).
Reasoning-capable models use DeepSeek's `thinking` plus `reasoning_effort` wire
format. DeepSeek supports `low`, `high`, and `max`; the adapter sends the other
levels as DeepSeek's documentation maps them:

| Level | Sent as |
| --- | --- |
| `minimal`, `low` | `low` |
| `medium`, `high`, `xhigh` | `high` |
| `max` | `max` |

Other values fail with `{:error, {:invalid_reasoning_effort, value}}`. Prior reasoning is
kept as opaque provider state, which `Tackle.Lib.LLM` replays only to the same
provider id and model.
Structured responses use DeepSeek's JSON-output mode and include the requested
schema in the system instruction.

## Providers

`adapter_id/0` (`"deepseek"`) names the adapter type. Several providers can
share the adapter, each with its own key and endpoint:

```elixir
alias Tackle.Lib.LLM.Provider

{:ok, work} = Provider.new("deepseek-work", Tackle.Plugins.DeepSeek)

{:ok, proxy} =
  Provider.new("deepseek-proxy", Tackle.Plugins.DeepSeek, %{
    "base_url" => "https://deepseek-proxy.example/v1"
  })
```

The selection passes `:provider_id` and `:provider_settings` to the adapter, and
hosts pass the same options to `login/1` and `usage/1`. Without them the
adapter acts as the default `"deepseek"` provider. The provider id is the
credential namespace; `Tackle.Lib.LLM` reports it as the response's
`:provider` and stamps it on replayable reasoning state.

Honoured provider settings:

| Key | Meaning |
| --- | --- |
| `"base_url"` | API base URL for chat completions and balance. An explicit `:base_url` option wins. |
| `"api_key_env"` | Environment variable read for an API key when none is stored. Defaults to `DEEPSEEK_API_KEY` for the `"deepseek"` provider and to none otherwise, so another provider never picks up that key by accident. |

## Provider caching

DeepSeek owns the context cache; the plugin does not maintain a local cache or
send invented cache-control fields. Cache reuse instead depends on stable,
append-only request prefixes. The adapter preserves message ordering, emits an
empty string (not `null`) for tool/reasoning-only assistant turns, and preserves
historical raw tool-argument JSON byte-for-byte after validating it. Cache hit
and write tokens are reported as disjoint usage buckets.

Override `:base_url` for a compatible endpoint and `:request` in tests. Model
requests are always streamed: the adapter implements only `stream/3`, which
`Tackle.Lib.LLM` also uses for non-streaming calls. HTTP retries are deliberately disabled so a request is never
replayed after visible stream output. There is no OAuth, WebSocket transport,
connection process, or persistent local cache in this plugin.

Price cards use DeepSeek's peak rates; DeepSeek bills off-peak requests at half
those rates where applicable.

## Development

```sh
mix deps.get
mix compile --warnings-as-errors
mix test
mix format --check-formatted 'mix.exs' 'lib/**/*.{ex,exs}' 'test/**/*.{ex,exs}'
```
