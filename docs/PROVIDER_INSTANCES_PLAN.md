# Provider instances

> **Status: implemented.** Deviations from the plan below:
>
> - Providers take an `"api_key_env"` setting. Only an adapter's default
>   provider falls back to its standard variable (`ollama-cloud` to
>   `OLLAMA_API_KEY`, `anthropic` to `ANTHROPIC_API_KEY`, `openrouter` to
>   `OPENROUTER_API_KEY`, `deepseek` to `DEEPSEEK_API_KEY`); other providers
>   read a variable only when they name it. Missing-key errors carry the
>   provider id.
> - An account created from a provider id records it as its `"base"` and
>   inherits that provider's merged settings, minus `"api_key_env"` (see §5).
> - `auth.json` accounts whose adapter a host does not include, whose id is
>   the id of a default provider of any of the host's adapters, or whose id a
>   `config.json` entry declares for another of the host's adapters are
>   skipped instead of failing; so are
>   `config.json` entries naming an adapter type the host does not include.
>   `login --as` refuses such names up front: a default provider's id with
>   `{:default_provider_name, NAME}`, the others with
>   `{:provider_adapter_conflict, NAME}`.
> - Selections carry `:provider_id`/`:provider_settings`
>   (`Selection.provider/1` rebuilds the struct) instead of `:provider` plus a
>   type-id `adapter_id`.
> - Adapters are passed explicitly: `Tackle.Providers.available_providers/2`
>   and every `Tackle.Auth.Flows` function take the host's adapter modules
>   first, and `Tackle.Config.load/1` takes `:available_adapters` or a
>   `:catalog`. The `:tackle, :adapters` application environment is gone.

## Goal

One adapter module can back several configured **providers**, each with its own
settings and login. Examples:

- `ollama` (local server) and `ollama-cloud` share one Ollama adapter.
- `codex-work` and `codex-personal` are two Codex subscriptions on the same
  adapter, logged in separately and chosen by model ref
  (`codex-work/gpt-5.5`).

Automatic failover or rotation between providers is out of scope.

## Before: the module was the identity

- A model ref is `"adapter_id/model"`. `Tackle.Lib.LLM.Selection.resolve/2`
  indexes adapters by calling `module.adapter_id()` and rejects duplicate ids
  (`packages/tackle_lib/lib/tackle_lib/llm/selection.ex`). `Decision.Selection`
  shares the same index.
- `Tackle.Plugins.Catalog` and `Tackle.Providers` deduplicate adapters by
  `adapter_id/0`; `Tackle.Auth.Flows` resolves an id to a module and stores
  credentials under `adapter.adapter_id()`.
- Adapters hard-code their id for credential namespaces, `provider_options`
  lookups, and refresh locks (`codex.ex` `@adapter_id "openai-codex"`, Anthropic,
  OpenRouter, both Ollama modules).
- Ollama cloud and local are two modules (`Tackle.Plugins.Ollama`,
  `Tackle.Plugins.OllamaLocal`) over a shared `Ollama.chat/4` profile.

Persisted refs (session journals, agent frontmatter `model:`, `RunRef`, workflow
`{model = ...}`, web `ChatStore`, SDK `session/new`) are plain strings and stay
unchanged as long as the ref prefix keeps resolving.

## Terminology

- **Adapter**: an LLM module. `adapter_id/0` becomes the adapter *type* id
  (`openai-codex`, `ollama`).
- **Provider**: a configured instance `{id, adapter, settings}`. The provider id
  is the model-ref prefix and the credential namespace.

Each adapter has default providers. Unless it declares otherwise, that is one
provider whose id equals `adapter_id/0` with empty settings, so every existing
ref and `auth.json` entry keeps working.

## Design

### 1. `tackle_lib`: provider struct and selection

- New `Tackle.Lib.LLM.Provider`:
  `%Provider{id: String.t(), adapter: module(), settings: map()}` with
  `new/1` (validates the id pattern and adapter callbacks) and `default/1`.
- New optional adapter callback `default_providers/0 :: [{id, settings}]`.
  When it is absent, the default is `[{adapter_id(), %{}}]`.
- `LLM.select/2`, `Decision.select/2` and `Selection.index_adapters/2` accept
  `[module() | Provider.t()]`. A bare module expands to its default providers.
  The index is keyed by **provider id**, so duplicates are
  `{:duplicate_provider_id, id}`.
- `LLM.Selection` and `Decision.Selection` gain `:provider` (the
  `Provider.t()`). `adapter_id` keeps holding the type id, and `ref` keeps the
  canonical `provider_id/model`. The reported usage/result `:provider` becomes
  the provider id.
- Optional instance-aware callbacks take settings and are preferred over the
  arity-0 versions when exported: `models/1`, `model_info/2`,
  `decision_models/1`, `local?/1`.
- `generate_with`/`stream`/`decide` inject `provider_id:` and
  `provider_settings:` into adapter opts. `Tackle.Auth.Flows` does the same
  for `login/logout/status/usage`. A small helper
  `Tackle.Lib.LLM.provider_id(opts, default)` keeps adapters short.

Bare modules stay valid, so third-party adapters keep working until they need
multiple instances.

### 2. Adapters read the provider id

Every first-party adapter replaces `@adapter_id` with `opts[:provider_id]` for:

- `CredentialStore.fetch/put` namespaces (Codex, Anthropic, Ollama).
- Refresh locks: `:global.trans({{module, :credential_refresh, handle, provider_id}, ...})`
  (Codex, Anthropic). Since replaced by
  `Tackle.Lib.CredentialStore.with_lock(handle, provider_id, fun)`, which
  `auth.json` holds across OS processes.
- Settings: read `opts[:provider_settings]` instead of
  `opts[:provider_options][@adapter_id]` (OpenRouter, Ollama).

Codex's WebSocket cache is already keyed by URL, account and token hash, so it
needs no change.

### 3. Ollama becomes one adapter

`Tackle.Plugins.OllamaLocal` is removed and its code moves into
`Tackle.Plugins.Ollama` (`adapter_id` `"ollama"`):

- Settings: `base_url`, `api_key` (`"required" | "none"`), `models`,
  `decision_models`, `local`.
- `default_providers/0` returns `ollama` (localhost, no key, `local: true`,
  models and decision models from settings/app env) and `ollama-cloud`
  (`https://ollama.com/v1`, key required, static catalog plus app-env models).
  Existing `ollama/...` and `ollama-cloud/...` refs and the `ollama-cloud`
  credential namespace keep resolving.
- `decide/2` and `local?/1` come over from `OllamaLocal`. Cloud providers are
  not local.
- App env moves from `config :tackle_ollama, Tackle.Plugins.OllamaLocal, ...`
  to settings keyed by provider id. `apps/tackle_cli/config/config.exs` and
  tests are updated.

**Breaking:** the `Tackle.Plugins.OllamaLocal` module and its app-env key go away.

### 4. Harness: where providers come from

The provider list is merged from three sources, lowest precedence first:

1. Adapter default providers (from the catalog's adapter modules).
2. Accounts created by `login --as` (stored in `auth.json`, see §5).
3. `config.json` `"providers"`:

   ```json
   "providers": {
     "codex-work":     {"adapter": "openai-codex"},
     "ollama":         {"adapter": "ollama", "models": ["qwen3:8b"]},
     "ollama-gpu-box": {"adapter": "ollama", "base_url": "http://gpu:11434/v1",
                        "api_key": "none", "local": true, "models": ["gpt-oss:20b"]}
   }
   ```

   `adapter` names a type id from the catalog. The rest of the entry is
   opaque settings, merged over that adapter's defaults for the same id. If an
   entry redeclares a default provider id with a different adapter,
   configuration fails with `{:provider_adapter_conflict, id}`. An entry
   naming an adapter type the host lacks is skipped, and so is an account
   that collides with a default or `config.json` provider of another adapter.

- `Tackle.Providers.available_providers/1` returns `[Provider.t()]`.
  `available_model_refs/1` and `default_model_ref/1` iterate providers.
  `Catalog` stays module-level, deduplicated by adapter type id.
- The existing `"provider_options"` key (a map keyed by id) and the
  `:provider_options` adapter opt are removed outright, with no deprecated
  alias. `"providers"` replaces them.
- A model ref always names a provider. `openai-codex/...` resolves only while a
  provider with id `openai-codex` exists. It never falls back to the adapter
  type.
- Call sites switch from adapter lists to provider lists: `Tackle.Config`,
  session loader, `Runtime.RootBackend`, narrator, watchdog,
  `tackle_workflow` decisions, `tackle_sdk` server,
  `Tackle.CLI.Distribution`. `tackle_phoenix` needs checking.

### 5. Login as a named account

```sh
tackle auth login openai-codex --as codex-work
tackle auth status            # lists providers: id, adapter, credential status
tackle auth logout codex-work
```

- The positional argument is a provider id or adapter type id. With
  `--as NAME`, the CLI records provider `NAME` on that adapter (for a provider
  id, its adapter), then runs the adapter's `login/1` with `provider_id: NAME`.
  Credentials are stored under `NAME`.
- `--as` takes no settings. When the positional argument is a provider id,
  the account inherits that provider's merged settings (defaults plus its
  `config.json` entry) except `"api_key_env"`, so
  `tackle auth login ollama-cloud --as cloud2` gives `cloud2` the cloud URL,
  required key, and catalog, with its own stored key. From an adapter type id
  the account starts without settings. Custom settings live only in
  `config.json`: to give `codex-work` a different base URL, declare
  `"codex-work"` there, and those settings merge over the account.
- `NAME` must be a valid provider id and must not belong to a provider or a
  recorded account of another adapter (even one this host lacks); otherwise
  login fails with `{:provider_adapter_conflict, NAME}` before the adapter's
  login runs. The account is recorded only after the login succeeded and its
  credentials were stored.
- Account records live in `auth.json`, not `config.json`. The harness never
  writes the user's config file, and an account only exists together with its
  credentials. Envelope v2:

  ```json
  {"version": 2,
   "providers": {"codex-work": {...credentials...}},
   "accounts":  {"codex-work": {"adapter": "openai-codex"},
                 "cloud2":     {"adapter": "ollama", "base": "ollama-cloud"}}}
  ```

  `Auth.Store` reads v1 as v2 with no accounts and writes v2. The
  `CredentialStore` behaviour is unchanged. Account functions are added to
  `Tackle.Auth` only.
- Logout of an `--as` account deletes its credentials and the account record.
  Logout of a default or `config.json` provider deletes only its credentials.
- Without `--as`, login behaves as today for the provider id given.

### 6. Frontends

- CLI model picker: already groups refs by prefix. Show the adapter type next
  to the provider id when they differ.
- Parser: add `--as` to `auth login`. `auth status` with no argument lists all
  providers.
- Web and SDK: pass providers through. No protocol change; refs are already
  strings.

## Breaking changes (approved; no backwards compatibility required)

- `Tackle.Plugins.OllamaLocal` is removed, and the app-env key moves.
- Selection structs gain `:provider`. The reported `:provider` in results/usage
  is the provider id. `{:duplicate_adapter_id, _}` becomes
  `{:duplicate_provider_id, _}`.
- `"provider_options"` in `config.json` and the `:provider_options` adapter opt
  are replaced by `"providers"` and `:provider_settings`.
- `auth.json` moves to version 2, so older binaries cannot read it after an
  upgrade.

## Implementation order

Each step keeps all affected projects green.

1. **tackle_lib:** `Provider`, selection over providers,
   `default_providers/0`, arity-1 callbacks, opt injection. Tests: bare
   module = default provider, two providers on one adapter, duplicate ids,
   unknown provider, instance-specific models/local flag, injected opts.
2. **Adapters:** Codex, Anthropic, OpenRouter, DeepSeek read
   `provider_id`/`provider_settings`. Tests: two Codex providers store, refresh
   and lock independently against a fake credential store.
3. **Ollama merge:** move `OllamaLocal` into `Ollama` and port
   `ollama_local_test.exs`. Tests: default `ollama`/`ollama-cloud` resolve, a
   custom local provider with its own base URL and models, decision selection
   locality per provider.
4. **Harness:** `config.json` `"providers"` parsing and validation,
   `available_providers/1`, auth store v2 plus accounts, `Auth.Provider` per
   provider, call-site migration. Tests: merge precedence, conflicts, v1→v2
   load, login/logout with `--as`.
5. **CLI/web/SDK:** `--as`, status listing, picker labels, `config.exs`,
   READMEs (`packages/tackle`, `packages/tackle_lib`, `packages/tackle_ollama`,
   `apps/tackle_cli`), migration notes.

## Decisions

- Custom provider settings live only in `config.json`. `--as` takes none.
- `"provider_options"` is dropped now, with no alias. Backwards compatibility
  is not a goal while the project is in development.
- A model ref always names a provider, never an adapter type.
- No automatic failover or rotation between providers for now.
