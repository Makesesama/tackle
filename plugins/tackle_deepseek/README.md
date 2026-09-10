# Tackle DeepSeek

DeepSeek provider plugin for Tackle. The adapter follows Pi's DeepSeek provider:
it uses DeepSeek's OpenAI-compatible chat-completions API at
`https://api.deepseek.com` and supports `deepseek-chat`, `deepseek-reasoner`,
and `deepseek-flash` (DeepSeek-V4.1-Flash, a 1M-context model with a 384K
maximum output).

## Usage

```elixir
{:ok, llm} =
  Tackle.Lib.LLM.select(
    [Tackle.Plugins.DeepSeek],
    "deepseek/deepseek-chat"
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
`Tackle.Lib.CredentialStore` is
also supported.

The adapter translates structured Tackle messages, native tools, JSON response
schemas, streamed text/reasoning/tool-call deltas, and DeepSeek cache usage.
For reasoning controls, pass `reasoning_effort: :low | :high | :max` (or
`:none` to disable thinking) in `:llm_opts`. Structured responses use
DeepSeek's JSON-output mode and include the requested schema in the system
instruction.

Override `:base_url` for a compatible endpoint and `:request` in tests. Model
requests are always streamed internally, while `generate/2` simply collects the
stream into one result. Price cards use DeepSeek's peak rates; DeepSeek bills
off-peak requests at half those rates.

## Development

```sh
mix deps.get
mix compile --warnings-as-errors
mix test
mix format --check-formatted 'mix.exs' 'lib/**/*.{ex,exs}' 'test/**/*.{ex,exs}'
```
