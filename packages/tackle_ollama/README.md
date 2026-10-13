# Tackle Ollama

Optional provider plugin for Ollama. `Tackle.Plugins.Ollama` (adapter type id
`ollama`) implements `Tackle.Lib.LLM` and `Tackle.Lib.Decision` for any Ollama
server: Ollama Cloud, a local server, or a self-hosted one. Each server is a
provider (`Tackle.Lib.LLM.Provider`) with its own id, settings, and login.

The bare module stands for two default providers:

| Provider id    | Base URL                    | API key  | Models                          | Local |
| -------------- | --------------------------- | -------- | ------------------------------- | ----- |
| `ollama`       | `http://localhost:11434/v1` | none     | host-configured (none built in) | yes   |
| `ollama-cloud` | `https://ollama.com/v1`     | required | curated catalog                 | no    |

Model refs are `provider_id/model`, so `ollama/qwen3:8b` and
`ollama-cloud/gpt-oss:120b` keep working, and Ollama Cloud keys stay in the
`ollama-cloud` credential namespace.

**Breaking:** `Tackle.Plugins.OllamaLocal` was removed and merged into
`Tackle.Plugins.Ollama`. Its application configuration moved to the
per-provider shape in [Application configuration](#application-configuration);
`provider_options` is no longer read.

## Use in an Elixir host

Add `{:tackle_ollama, path: "packages/tackle_ollama"}` to your Mix dependencies
(adjust the path relative to your project), then set `OLLAMA_API_KEY` to an
[Ollama API key](https://ollama.com/settings/keys) for Ollama Cloud.

```elixir
{:ok, llm} = Tackle.Lib.LLM.select([Tackle.Plugins.Ollama], "ollama-cloud/gpt-oss:120b")

state = Tackle.Lib.new(llm: llm)
```

A harness host can register it with `config :tackle, adapters:
[Tackle.Plugins.Ollama]`. This replaces the host's adapter list; include any
other adapters you want to keep.

To use another server, pass a provider instead of (or next to) the module:

```elixir
{:ok, gpu_box} =
  Tackle.Lib.LLM.Provider.new("gpu-box", Tackle.Plugins.Ollama, %{
    "base_url" => "http://gpu:11434/v1",
    "api_key" => "none",
    "local" => true,
    "models" => ["gpt-oss:20b"],
    "decision_models" => ["tev1:4b"]
  })

{:ok, llm} = Tackle.Lib.LLM.select([Tackle.Plugins.Ollama, gpu_box], "gpu-box/gpt-oss:20b")
```

## Provider settings

Settings are a JSON-compatible map with string keys, so they can also come
from a host's configuration file. A provider uses exactly the settings it is
given; missing keys take these defaults:

| Key                 | Meaning                                                                                  | Default                     |
| ------------------- | ---------------------------------------------------------------------------------------- | --------------------------- |
| `"base_url"`        | OpenAI-compatible base URL                                                               | `http://localhost:11434/v1` |
| `"api_key"`         | `"required"` sends a bearer key; `"none"` sends none and never reads credentials         | `"none"`                    |
| `"api_key_env"`     | environment variable read for the key after the credential store                        | none                        |
| `"models"`          | selectable chat model ids                                                                | `[]`                        |
| `"decision_models"` | selectable decision model ids                                                            | `[]`                        |
| `"model_info"`      | model id → `Tackle.Lib.ModelInfo` fields, e.g. `{"context_window": 131072}`              | `{}`                        |
| `"local"`           | decision models run on hardware the user controls (hosts may skip them in token budgets) | `false`                     |

The `ollama` default provider sets `"local": true`. The `ollama-cloud` default
provider sets `"api_key": "required"`, `"api_key_env": "OLLAMA_API_KEY"`, and
`"models"` to the catalog. Custom providers read no environment variable
unless they name one, so a cloud key is never sent to another server by
accident. `"local"` is not checked against the base URL.

Malformed `"models"`, `"decision_models"`, `"model_info"`, and `"local"`
values are reported by selection (for example
`{:invalid_model_id, "ollama", ""}` or `{:invalid_local_flag, id, value}`). A
non-string `"base_url"` returns
`{:error, {:invalid_provider_settings, provider_id, {"base_url", value}}}`, and
an unknown `"api_key"` returns
`{:error, {:invalid_provider_settings, provider_id, {"api_key", :invalid}}}`
(the value is not echoed, since it may be a key pasted in by mistake), before
any request is sent. Settings that are not a map return
`{:error, {:invalid_provider_settings, provider_id, :not_a_map}}`.

## Application configuration

Hosts adjust the default providers by provider id. Each entry merges key by key
(one level) over the built-in settings of that id; entries with other ids add
providers:

```elixir
config :tackle_ollama, Tackle.Plugins.Ollama,
  providers: %{
    "ollama" => %{"models" => ["gemma4:12b"], "decision_models" => ["tev1:4b"]},
    "ollama-cloud" => %{
      "model_info" => %{"gpt-oss:120b" => %{"context_window" => 131_072}}
    }
  }
```

`"models"` replaces the built-in list. To extend the cloud catalog, list the
catalog ids as well (`Tackle.Plugins.Ollama.catalog_models/0`). Settings from a
host's configuration file, such as the harness `config.json` `"providers"`,
are merged over `default_providers/0` by the host, so they take precedence
over application configuration.

## Use in the CLI

The CLI bundles this adapter, including in its Nix builds. No plugin
registration or local Ollama installation is required:

```sh
# Either export OLLAMA_API_KEY or store a key interactively:
tackle auth login ollama-cloud
tackle --model ollama-cloud/gpt-oss:120b
# Or use GLM-5.3 (no :cloud suffix):
tackle --model ollama-cloud/glm-5.3
```

From `apps/tackle_cli`, use `mix tackle` in place of `tackle`. Models also
appear in the CLI model picker. Remove any separate Ollama entry from
`plugins.json` when using the bundled adapter to avoid duplicate registration.

The CLI's distribution config makes `ollama/tev1:4b` selectable as a decision
model (for the command watchdog) and `ollama/gemma4:12b` as a chat model (for
narration). Other local models need `"models"` configured for the `ollama`
provider.

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

Only providers with `"api_key": "required"` use a key. Precedence: the
per-request `:api_key`, then the host-owned `Tackle.Lib.CredentialStore` under
the provider id (`"api_key"` or `"key"`), then the `"api_key_env"` variable.
Keys are trimmed and validated before building a request; a missing key is
`{:error, {:missing_ollama_api_key, provider_id}}`.

- `login/1` prompts for a key through a `Tackle.Lib.Interaction` handle and
  returns credentials for the host to persist under the provider id. Keyless
  providers return `{:error, {:login_not_required, provider_id}}`.
- `status/1` returns `{:ok, :stored}` when the store or the environment
  variable has a key, `{:ok, :missing}` otherwise, and `{:ok, :not_required}`
  for keyless providers.
- Logout uses the host's default flow (deleting the stored credentials). No
  account usage callback is exposed.

Called directly rather than through a selection, the adapter reads
`:provider_id` (default `ollama`) and `:provider_settings`; without settings it
uses the default settings for that id.

## Models and metadata

The `ollama-cloud` catalog is small and deterministic: `gpt-oss:120b`,
`gpt-oss:20b`, `kimi-k3`, `deepseek-v4.1-flash`, and `glm-5.3`. These
direct-cloud ids come from [Ollama's model listing](https://ollama.com/api/tags),
not local `:cloud` aliases. Availability may change. Nothing is discovered
from any server, at startup or later: local models are selectable only when
configured.

Limits and pricing are **unknown by default**, not zero-cost estimates.
`model_info/2` returns only the configured `"model_info"` entry. See
`Tackle.Lib.ModelInfo` for the optional limits and price-card contract.

## Generation

Supports streaming text/reasoning, native function tools, JSON Schema response
formats, token usage, cancellation between chunks, and explicit context-overflow
errors. Both `generate/2` and `stream/3` use SSE transport to
`<base_url>/chat/completions`. Truncated streams and output-token exhaustion
return errors rather than incomplete tool calls.

Standard options include `:model`, `:messages`, `:system`, `:tools`,
`:temperature`, `:top_p`, `:max_tokens`, `:stop`, and `:cancellation_signal`.
Additional options:

- `:reasoning_effort`: model-defined nonempty string or atom, forwarded to
  Ollama. `:off`/`:none` map to `"none"`; omitted means the model's default.
- `:tool_choice`: OpenAI-compatible tool choice; defaults to `"auto"` with tools.
- `:base_url`: overrides the provider's `"base_url"`. Only use trusted
  endpoints; a required key is sent there.
- `:receive_timeout`: defaults to 120,000 ms.

Results and usage report the provider id as `:provider`. Tool results are
text-only in this adapter; image parts become an explicit omission note.
Reasoning is replayed only for the same provider id and model. Missing tool-call
ids are synthesized as `<provider_id>-generated-...`, unique per completion and
stable across stream events and subsequent tool history.

## Decisions

```elixir
{:ok, decision} = Tackle.Lib.Decision.select([Tackle.Plugins.Ollama], "ollama/tev1:4b")

question =
  Tackle.Lib.Decision.Question.choice("verdict", "Is this command stuck?", %{
    "progressing" => "Output is still advancing",
    "stalled" => "No progress is being made"
  })

{:ok, result} = Tackle.Lib.Decision.decide(decision, "command: make test ...", [question], [])
result.answers["verdict"].choice
```

Decisions use Ollama's [System One](https://docs.ollama.com/capabilities/decision)
endpoint, `POST <base_url>/systemone`, with decision models such as `tev1:4b`
listed in the provider's `"decision_models"`. The base URL and key follow the
same rules as chat. Requests are validated against the `Tackle.Lib.Decision`
limits before sending. Every asked question must be answered with its own type;
`choice` answers must name a known option, and a `score` without an explicit
value is the probability-weighted average of its zero-based levels. Non-2xx
responses return `{:error, {:http_error, status, body}}`. `decide/2` honours
`:cancellation_signal` (an in-flight request is abandoned) and
`:receive_timeout` (default 60,000 ms, since a model may load on first use).

A selection's `local` flag comes from the provider's `"local"` setting, so
hosts such as workflow `tackle.classify` leave usage of local providers out of
token budgets.

## Validation

```sh
mix compile --warnings-as-errors
mix test
mix format --check-formatted mix.exs 'lib/**/*.{ex,exs}' 'test/**/*.{ex,exs}'
```

Tests inject deterministic transports; they never need credentials or paid
model calls. API references: [cloud](https://docs.ollama.com/cloud) and
[OpenAI compatibility](https://docs.ollama.com/api/openai-compatibility).
