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
while the V4 cards expose 384,000 tokens. Although
`deepseek-v4-flash-vision-exp` is a
vision-capable provider model, Tackle's current provider-neutral message
contract is text-only; this plugin does not yet serialize images.

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

The API key is resolved in this order: `:api_key`, the adapter's
`"deepseek"` credential-store namespace (`"api_key"` or `"key"`), then the
`DEEPSEEK_API_KEY` environment variable. The bundled CLI can populate the store
with `mix tackle auth login deepseek`; depending on terminal support, its prompt
may be visible. Supplying it explicitly or through a host-owned
`Tackle.Lib.CredentialStore` is also supported.

The adapter translates structured Tackle messages, native tools, JSON response
schemas, and streamed text, reasoning, and tool-call deltas. A successful
stream must contain a recognized finish reason followed by `[DONE]`. Usage is
held until that terminal validation succeeds, and tool calls are returned only
after their identity and JSON-object arguments have been validated.

For reasoning controls, pass `reasoning_effort: :low | :high | :max` (or
`:none`/`:off` to disable thinking) in `:llm_opts`. Reasoning-capable models use
DeepSeek's `thinking` plus `reasoning_effort` wire format. Prior reasoning is
replayed only when opaque state belongs to this adapter and the same model.
Structured responses use DeepSeek's JSON-output mode and include the requested
schema in the system instruction.

## Provider caching

DeepSeek owns the context cache; the plugin does not maintain a local cache or
send invented cache-control fields. Cache reuse instead depends on stable,
append-only request prefixes. The adapter preserves message ordering, emits an
empty string (not `null`) for tool/reasoning-only assistant turns, and preserves
historical raw tool-argument JSON byte-for-byte after validating it. Cache hit
and write tokens are reported as disjoint usage buckets.

Override `:base_url` for a compatible endpoint and `:request` in tests. Model
requests are always streamed internally, while `generate/2` collects the stream
into one result. HTTP retries are deliberately disabled so a request is never
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
