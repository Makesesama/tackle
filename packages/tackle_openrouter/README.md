# Tackle OpenRouter

OpenRouter provider plugin for Tackle. The adapter uses OpenRouter's
OpenAI-compatible streaming Chat Completions API at
`https://openrouter.ai/api/v1`.

OpenRouter model ids keep their vendor prefix, so canonical model references
contain two slashes: `openrouter/anthropic/claude-sonnet-5.5`.
`Tackle.Lib.LLM.select/2` splits only at the first slash.

## Models

`models/0` returns a curated catalog with context limits and price cards taken
from OpenRouter's model listing:

- `anthropic/claude-opus-5.5`, `anthropic/claude-sonnet-5.5`,
  `anthropic/claude-fable-5.1`
- `openai/gpt-6.1-sol`, `openai/gpt-6-astra`, `openai/gpt-6-luna`
- `google/gemini-3.8-flash`
- `x-ai/grok-4.7`
- `deepseek/deepseek-v4.1-flash`
- `moonshotai/kimi-k3`
- `z-ai/glm-5.3`
- `qwen/qwen3.8-max-0902`

OpenRouter lists hundreds of models. Make others selectable through application
configuration, optionally with limits and pricing:

```elixir
config :tackle_openrouter,
  models: [
    "meta-llama/llama-5-maverick",
    {"mistralai/devstral-3",
     %{
       context_window: 262_144,
       max_output_tokens: 65_536,
       pricing: %{input: 0.4, output: 2.0, cache_read: 0.04, cache_write: 0}
     }}
  ]
```

Catalog prices are estimates in USD per million tokens. A `pricing` map needs
all four of `input`, `output`, `cache_read`, and `cache_write`. OpenRouter
reports the billed `cost` with every response, and Tackle keeps that reported
cost instead of an estimate.

## Usage

```elixir
{:ok, llm} =
  Tackle.Lib.LLM.select(
    [Tackle.Plugins.OpenRouter],
    "openrouter/anthropic/claude-sonnet-5.5"
  )

state =
  Tackle.Lib.new(
    llm: llm,
    llm_opts: [api_key: System.fetch_env!("OPENROUTER_API_KEY")]
  )
```

The API key is resolved in this order: `:api_key`, the provider's
credential-store namespace (`"api_key"` or `"key"`; `"openrouter"` for the
default provider), then an environment variable: the provider's
`"api_key_env"` setting, or `OPENROUTER_API_KEY` for the default `"openrouter"`
provider only. A missing key is
`{:error, {:missing_openrouter_api_key, provider_id}}`. `login/1` prompts for a key through
a `Tackle.Lib.Interaction` handle, and `usage/1` returns the key's credit usage
and limit from `GET /key`.

## Providers

`adapter_id/0` (`"openrouter"`) names the adapter type. Several providers can
share the adapter, each with its own key and settings, for example
`openrouter-work/z-ai/glm-5.3` and `openrouter-zdr/z-ai/glm-5.3`:

```elixir
alias Tackle.Lib.LLM.Provider

{:ok, work} = Provider.new("openrouter-work", Tackle.Plugins.OpenRouter)

{:ok, zdr} =
  Provider.new("openrouter-zdr", Tackle.Plugins.OpenRouter, %{
    "provider_routing" => %{"z-ai/glm-5.3" => %{"only" => ["mistral/zdr"], "zdr" => true}}
  })
```

The selection passes `:provider_id` and `:provider_settings` to the adapter, and
hosts pass the same options to `login/1` and `usage/1`. Without them the
adapter acts as the default `"openrouter"` provider. The provider id is the
credential namespace; `Tackle.Lib.LLM` reports it as the response's
`:provider` and stamps it on replayable reasoning state.

Honoured provider settings:

| Key | Meaning |
| --- | --- |
| `"provider_routing"` | Map of model id to route; see [Provider routing](#provider-routing). |
| `"base_url"` | API base URL. An explicit `:base_url` option wins. |
| `"api_key_env"` | Environment variable read for an API key when none is stored. Defaults to `OPENROUTER_API_KEY` for the `"openrouter"` provider and to none otherwise, so another provider never picks up that key by accident. |

## Options

Besides the standard Tackle options (`:messages`, `:system`, `:tools`,
`:temperature`, `:max_tokens`, `:session_id`, `:cancellation_signal`), the
adapter accepts these `:llm_opts`:

- `:reasoning_effort`: any `Tackle.Lib.Thinking` level (`minimal` through
  `max`, as a string or atom), or `:none`/`:off` to disable reasoning. Sent
  unchanged as OpenRouter's unified `reasoning.effort` (`off` as `"none"`);
  OpenRouter maps it to the nearest level the model supports. Models with
  mandatory reasoning reject `"none"`; leave the option out (as
  `Tackle.Lib.Thinking.put_llm_opts/2` does for `"off"`) to use the model's
  default instead. Other values fail with
  `{:error, {:invalid_reasoning_effort, value}}`.
- `:provider_preferences`: OpenRouter's `provider` routing object for this
  request, as a map or keyword list, for example
  `[order: ["anthropic"], allow_fallbacks: false]`. Its fields override the
  model's configured route (see [Provider routing](#provider-routing)). Other
  values return `{:error, {:invalid_provider_preferences, value}}`.
- `:cache_control`: `false` to disable automatic Anthropic prompt caching, or a
  map such as `%{type: "ephemeral", ttl: "1h"}` to override it.
- `:app_url` and `:app_title`: opt-in app attribution headers (`HTTP-Referer`,
  `X-Title`). Nothing identifying is sent by default.
- `:user_id`, `:top_p`, `:stop`, `:tool_choice`, `:base_url`,
  `:receive_timeout`.

## Provider routing

By default OpenRouter load-balances each request across the providers serving
the model, weighted by price and recent uptime. To pin a model to one provider
endpoint, configure a route for it:

```elixir
config :tackle_openrouter,
  provider_routing: %{
    "z-ai/glm-5.3" => [only: ["mistral/zdr"], allow_fallbacks: false, zdr: true]
  }
```

Each route is sent as OpenRouter's
[`provider` object](https://openrouter.ai/docs/guides/routing/provider-selection)
whenever that model is used; models without a route keep the default load
balancing.

A provider's `"provider_routing"` setting replaces the application-config route
for the same model; application-config routes remain the defaults for other
models. Tackle CLI users set it without rebuilding, as a provider entry under
`"providers"` in `$TACKLE_HOME/config.json` (default `~/.tackle/config.json`):

```json
{
  "providers": {
    "openrouter": {
      "adapter": "openrouter",
      "provider_routing": {
        "z-ai/glm-5.3": {"only": ["mistral/zdr"], "allow_fallbacks": false, "zdr": true}
      }
    }
  }
}
```

A `"provider_routing"` value that is not a map of routes returns
`{:error, {:invalid_provider_routing, value}}`.

Useful fields:

- `only`: the provider slugs allowed for the request. A base slug such as
  `"mistral"` matches all of that provider's endpoints; a full slug such as
  `"mistral/zdr"` targets exactly one. Copy endpoint slugs from the model page
  or `GET /api/v1/models/<vendor>/<model>/endpoints` (`tag`).
- `order` and `allow_fallbacks: false`: try providers in a fixed order, and fail
  instead of falling back to others.
- `zdr: true` or `data_collection: "deny"`: restrict routing to zero-data-retention
  or non-collecting endpoints. With `zdr: true`, a pinned endpoint that stops
  qualifying fails the request instead of quietly sending data elsewhere.
- `sort`, `quantizations`, `ignore`, `max_price`: see OpenRouter's documentation.

A request's `:provider_preferences` are merged over the model's route, field by
field. A malformed route returns
`{:error, {:invalid_provider_routing, model, value}}` before any request is
sent. The configured catalog price card is OpenRouter's listing price, which can
differ from the pinned provider's rate; the billed `cost` OpenRouter reports is
used for accounting either way.

## Behaviour

- **Streaming.** Requests are always streamed: the adapter implements only
  `stream/3`, which `Tackle.Lib.LLM` also uses for non-streaming calls.
  Keep-alive comments are ignored. A successful stream must contain a recognized
  finish reason followed by `[DONE]`. OpenRouter's usage frame, which repeats
  the finish reason, is treated as accounting, and any other output after the
  finish reason is an error. Mid-stream provider errors on a committed `200`
  response are returned as `Tackle.Lib.LLM.Error`s classified by their code. Tool calls are
  returned only after their identity and JSON-object arguments are validated.
- **Reasoning.** Reasoning text is streamed as reasoning deltas. Structured
  `reasoning_details` (signatures, encrypted blocks) are kept as opaque provider
  state, which `Tackle.Lib.LLM` replays on later turns only to the same provider
  id and model; some models require it when continuing after tool calls.
- **Caching.** For `anthropic/*` models the adapter sends a top-level
  `cache_control`, so OpenRouter places and advances the cache breakpoint
  itself and the message projection stays byte-identical between turns. Other
  upstreams cache implicitly. Tackle's stable `:session_id` is sent as
  OpenRouter's `session_id`, the sticky-routing key that keeps a conversation on
  the provider that holds its cache. Ids longer than OpenRouter's 256-byte limit
  are sent as their SHA-256 hex digest.
- **Structured output.** Structured responses request `json_schema` output and
  also state the schema in the system instruction, because upstreams without
  schema support drop the parameter.
- **Tool results** are text-only. Image parts become an explicit
  `[image content omitted: ...]` note.
- **Errors.** Failures are `Tackle.Lib.LLM.Error`s with the HTTP status,
  `Retry-After`, and the decoded error body as `details`; a mid-stream error
  event is classified by its code (OpenRouter relays the upstream status there).
  Only error messages that name a context limit become
  `:context_window_exceeded`, including an overflow reported on an already
  committed stream before any output. Rate limits are `:rate_limited` and
  insufficient credits (`402`) `:quota_exceeded`. HTTP retries in the adapter
  are disabled so a request is never replayed after visible stream output; the
  loop's retry policy decides.
- **API keys** from every source are trimmed, and keys containing spaces or
  control characters are rejected with `:invalid_api_key` before a request is
  built.

Override `:base_url` for a compatible endpoint and `:request` in tests.

## Development

```sh
mix deps.get
mix compile --warnings-as-errors
mix test
mix format --check-formatted 'mix.exs' 'lib/**/*.{ex,exs}' 'test/**/*.{ex,exs}'
```
