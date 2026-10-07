# Tackle Ollama Cloud

Optional `Tackle.Lib.LLM` provider plugin, connecting directly to
`https://ollama.com/v1/chat/completions`. No local Ollama installation is needed.

## Use in an Elixir host

Add `{:tackle_ollama, path: "packages/tackle_ollama"}` to your Mix dependencies
(adjust the path relative to your project), then set `OLLAMA_API_KEY` to an
[Ollama API key](https://ollama.com/settings/keys).

```elixir
{:ok, llm} =
  Tackle.Lib.LLM.select([Tackle.Plugins.Ollama], "ollama-cloud/gpt-oss:120b")

state = Tackle.Lib.new(llm: llm)
```

A harness host can register it with `config :tackle, adapters:
[Tackle.Plugins.Ollama]`. This replaces the host's adapter list; include any
other adapters you want to keep. The library's compatibility default is
`config :tackle_lib, llm: Tackle.Plugins.Ollama`; pass `model:` when generating.

## Use in the CLI

The CLI bundles this adapter, including in its Nix builds. No plugin
registration or local Ollama installation is required:

```sh
# Either export OLLAMA_API_KEY or store a key interactively:
tackle auth login ollama-cloud
tackle --model ollama-cloud/gpt-oss:120b
```

From `apps/tackle_cli`, use `mix tackle` in place of `tackle`. Models also
appear in the CLI model picker. Remove any separate Ollama entry from
`plugins.json` when using the bundled adapter to avoid duplicate registration.

## Enable in another host

The web distribution does not bundle this adapter. Build it as a
trusted plugin with a compatible Elixir/OTP toolchain:

```sh
cd packages/tackle_ollama
MIX_ENV=prod mix deps.get
MIX_ENV=prod mix compile
```

Merge this entry into `$TACKLE_HOME/plugins.json` (normally
`~/.tackle/plugins.json`), using your absolute checkout path:

```json
{
  "version": 1,
  "projects": [
    {
      "path": "/absolute/path/to/tackle/packages/tackle_ollama",
      "app": "tackle_ollama",
      "adapters": ["Tackle.Plugins.Ollama"]
    }
  ]
}
```

Restart the host. With `OLLAMA_API_KEY` exported, select
`ollama-cloud/gpt-oss:120b` in the model picker. Use a separate `TACKLE_HOME`
for this host if you also run the CLI: a shared Ollama plugin entry conflicts
with the CLI's bundled application and prevents CLI startup. See
[plugin loading](../../docs/PLUGINS.md) for trust, build compatibility, and
dependency-conflict limitations. Enabling a project does not select its model
automatically.

## Authentication

Key precedence: per-request `:api_key`, host-owned `Tackle.Lib.CredentialStore`
in the `"ollama-cloud"` namespace (`"api_key"` or `"key"`), then
`OLLAMA_API_KEY`. Keys are trimmed and validated before building a request.
`login/1` returns credentials for the host to persist. Logout/status use the
host's default credential flows. No account usage callback is exposed.

## Models and metadata

`models/0` returns a small, deterministic catalog: `gpt-oss:120b`,
`gpt-oss:20b`, `kimi-k3`, and `deepseek-v4.1-flash`. These direct-cloud ids come
from [Ollama's model listing](https://ollama.com/api/tags), not local
`:cloud` aliases. Availability may change; no network discovery runs at startup.

Hosts can add ids and supply metadata, including overrides for curated ids:

```elixir
config :tackle_ollama,
  models: ["gemma4:31b", {"gpt-oss:120b", %{context_window: 131_072}}]
```

Limits and pricing are **unknown by default**, not zero-cost estimates.
`model_info/1` returns only host-configured metadata. See `Tackle.Lib.ModelInfo`
for the optional limits and price-card contract.

## Generation

Supports streaming text/reasoning, native function tools, JSON Schema response
formats, token usage, cancellation between chunks, and explicit context-overflow
errors. Both `generate/2` and `stream/3` use SSE transport. Truncated streams and
output-token exhaustion return errors rather than incomplete tool calls.

Standard options include `:model`, `:messages`, `:system`, `:tools`,
`:temperature`, `:top_p`, `:max_tokens`, `:stop`, and `:cancellation_signal`.
Additional options:

- `:reasoning_effort`: model-defined nonempty string or atom, forwarded to
  Ollama. `:off`/`:none` map to `"none"`; omitted means the model's default.
- `:tool_choice`: OpenAI-compatible tool choice; defaults to `"auto"` with tools.
- `:base_url`: override the OpenAI-compatible base URL (default
  `https://ollama.com/v1`). Only use trusted endpoints; the key is sent there.
- `:receive_timeout`: defaults to 120,000 ms.

Tool results are text-only in this adapter; image parts become an explicit
omission note. Reasoning replay is restricted to this provider and model.
Missing provider tool-call ids are synthesized uniquely per completion and kept
stable across stream events and subsequent tool history.

## Validation

```sh
mix compile --warnings-as-errors
mix test
mix format --check-formatted mix.exs 'lib/**/*.{ex,exs}' 'test/**/*.{ex,exs}'
```

Tests inject deterministic transports; they never need credentials or paid
model calls. API references: [cloud](https://docs.ollama.com/cloud) and
[OpenAI compatibility](https://docs.ollama.com/api/openai-compatibility).
