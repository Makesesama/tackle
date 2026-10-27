defmodule Tackle.Config do
  @moduledoc """
  Validated, frontend-independent configuration for one Tackle session.

  `new/1` is the pure validation boundary for already-resolved options. `load/1`
  reads its sources (`Tackle.Config.Sources.read/1`) and builds the
  configuration from them with `from_sources/2`, which applies the harness
  configuration precedence and validates like `new/1`; neither resolves
  module names from file or environment data. A host that builds several
  configurations for one workspace reads the sources once and calls
  `from_sources/2` for each, as `Tackle.Coding.scope_spec/2` does.
  A trusted host may supply a `Tackle.Plugins.Catalog` to `load/1` for
  prevalidated adapter and hook selection. Catalog tools require a separate
  explicit grant by the host. Adapter modules are executable types; a session
  selects models from providers (`Tackle.Lib.LLM.Provider`), configured
  instances of those adapters (see `Tackle.Plugins`).

  Harness sessions always execute tools concurrently
  (`Tackle.Lib.Tool.Policy.concurrent/0`) under the session's own tool supervisor.
  `:tool_policy` is not a harness option: `Tackle.Lib` still supports sequential
  execution for hosts that need it, but the Tackle runtime pins concurrency. See
  the tool policy section of the [Tackle.Lib guide](https://github.com/Makesesama/tackle/blob/main/packages/tackle_lib/README.md)
  for the difference between the two modes.
  """

  alias Tackle.Config.Narration
  alias Tackle.Config.Options
  alias Tackle.Config.Prompt
  alias Tackle.Config.SessionTitles
  alias Tackle.Config.Sources
  alias Tackle.Config.Watchdog
  alias Tackle.Elixir.CompileGate
  alias Tackle.Elixir.CompileGate.Settings, as: CompileGateSettings
  alias Tackle.Lib.Compaction.Config, as: CompactionConfig
  alias Tackle.Lib.Decision
  alias Tackle.Lib.Hook
  alias Tackle.Lib.ID
  alias Tackle.Lib.LLM
  alias Tackle.Lib.LLM.Provider
  alias Tackle.Lib.LLM.Selection
  alias Tackle.Lib.Retry
  alias Tackle.Lib.Thinking
  alias Tackle.Lib.Tool
  alias Tackle.Lib.Tool.Policy
  alias Tackle.Lib.Tool.Schema
  alias Tackle.Review.Settings, as: ReviewSettings
  alias Tackle.SystemPrompt

  # Each entry point reports a malformed option list with its own tags.
  @new_option_errors {:invalid_options, :duplicate_option, :unknown_options}
  @update_option_errors {:invalid_update_options, :duplicate_update_option,
                         :unknown_update_options}
  @update_option_keys [:model, :thinking, :max_iterations, :context, :llm_opts]

  @reserved_llm_option_names MapSet.new([
                               "credential_store",
                               "credentials",
                               "access_token",
                               "refresh_token",
                               "bearer_token",
                               "token",
                               "api_key",
                               "client_secret",
                               "password",
                               "authorization"
                             ])

  @option_keys [
    :providers,
    :model,
    :tools,
    :hooks,
    :system_prompt,
    :context,
    :max_iterations,
    :thinking,
    :llm_opts,
    :id_generator,
    :llm_stream,
    :retry,
    :compaction,
    :session_titles,
    :watchdog,
    :narration,
    :decision_model,
    :review,
    :agents,
    :compile_gate
  ]

  @agent_setting_keys [:model, :thinking]
  @enforce_keys [:providers, :model_ref, :llm]
  defstruct providers: [],
            model_ref: nil,
            llm: nil,
            tools: [],
            hooks: [],
            system_prompt: nil,
            context: %{},
            max_iterations: :infinity,
            llm_opts: [],
            id_generator: &ID.uuid4/0,
            llm_stream: false,
            retry: Retry.new!(),
            compaction: nil,
            session_titles: nil,
            watchdog: nil,
            narration: nil,
            agents: %{},
            compile_gate: nil

  @type t :: %__MODULE__{
          providers: [Provider.t()],
          model_ref: String.t(),
          llm: Selection.t(),
          tools: [module()],
          hooks: [module()],
          system_prompt: String.t() | nil,
          context: map(),
          max_iterations: pos_integer() | :infinity,
          llm_opts: keyword(),
          id_generator: ID.generator(),
          llm_stream: boolean(),
          retry: Retry.t(),
          compaction: CompactionConfig.t() | nil,
          session_titles: SessionTitles.t() | nil,
          watchdog: Watchdog.t() | nil,
          narration: Narration.t() | nil,
          agents: %{optional(String.t()) => agent_settings()},
          compile_gate: CompileGateSettings.t() | nil
        }

  @typedoc """
  Settings that replace a subagent profile's own `model` and `thinking`; see
  `Tackle.Coding`.
  """
  @type agent_settings :: %{optional(:model) => String.t(), optional(:thinking) => String.t()}

  @doc """
  Loads session configuration from defaults, `config.json`, the project's
  `.tackle/config.json`, environment, and explicit overrides, in that order.

  Each setting takes its value from the last of those sources that sets it,
  and only that value is checked, so an invalid `TACKLE_THINKING` is an error
  only when no override sets the thinking level. Overrides set it with
  `:thinking` or `llm_opts: [reasoning_effort: level]` (`:thinking` wins when
  both are given). The files are validated as a whole, and their errors,
  including invalid values only they set, are `{:config_file, path, reason}`.

  The project file is the nearest `.tackle/config.json` at or above the working
  directory, stopping at the Git root (`Tackle.ProjectFiles`). It is read
  through the session executor (the `:context` override's `:executor`, which
  is validated before anything is read), layered over `$TACKLE_HOME/config.json` with
  JSON objects merged recursively, and may not set `providers`: it selects
  models and settings among the providers the user configured. Nor may it set
  the CLI's `show_subagent_sidebar` and `jail` fields (see `Tackle.Config.File`).

  The adapters are explicit: either `:available_adapters`, executable
  modules chosen by the host, or a trusted host's `:catalog`, which selects
  its adapter and hook modules. Without either, the result is
  `{:error, {:missing_option, :available_adapters}}`; specifying both adapter
  sources (`{:error, :conflicting_adapter_sources}`), or overriding catalog
  hooks, is an error. Catalog tools are not granted by this option.
  Configuration data can select declared model references and declare
  providers of those adapters (the `config.json` `"providers"` object) but
  cannot name or load modules.

  The session's providers are merged by `Tackle.Plugins.provider_entries/2`
  from the adapters' default providers, the recorded accounts, and the
  `config.json` providers, and must then offer a model, whichever source
  supplied the adapters. `:accounts` (`t:Tackle.Plugins.accounts/0`)
  defaults to `Tackle.Auth.accounts/0`. Tests and embedding hosts may supply
  an `:env` map; normal callers use the process environment. `:cwd` selects the working
  directory used for prompt discovery and built-in tools.

  Discovered `.agents/skills` are offered to the session together with
  `:builtin_skills`, a list of host-supplied skills from
  `Tackle.Skills.builtin/2` (file skills override them by name). Only skills
  whose required tools the session has are offered (`Tackle.Skills.available/2`).
  When any skill is offered, the session is also granted
  `Tackle.Tools.LoadSkill`, the single way the model loads a skill, and the
  offered skills are placed in the session context under `:skills` for that
  tool to serve.

  `instructions: false` (default `true`) leaves the instruction files
  (`APPEND_SYSTEM.md`, `AGENTS.md`) and skills out of the session: the
  system prompt is only the base prompt and the working directory, and no
  skill or `load_skill` tool is offered. `Tackle.Coding` uses it for
  profiles that set `instructions: false`, such as the code review stages.

  An option list that is not a keyword list is
  `{:error, {:invalid_loader_options, opts}}`, a repeated option
  `{:error, {:duplicate_loader_option, key}}`, and unknown options
  `{:error, {:unknown_loader_options, keys}}`; an invalid option value is
  `{:error, {:invalid_option, key, value}}`.
  """
  @spec load(keyword()) :: {:ok, t()} | {:error, term()}
  def load(opts) do
    with {:ok, sources} <- Sources.read(opts), do: from_sources(sources)
  end

  @doc """
  Builds a configuration from sources `Tackle.Config.Sources.read/1` read,
  as `load/1` does, without reading anything.

  Options:

    * `:overrides` - overrides merged over those the sources were read with.
      They may not set `:providers` or `:context`, whose executor the sources
      were read through (`{:reserved_override, key}`), nor `:hooks` when a
      catalog selected them.
    * `:instructions` - whether the configuration gets the instruction files
      and skills (default: as the sources were read). Sources read with
      `instructions: false` hold neither, so `true` is then an error.
  """
  @spec from_sources(Sources.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_sources(%Sources{} = sources, opts \\ []) do
    with :ok <- Options.validate_list(opts, [:overrides, :instructions], @new_option_errors),
         extra = Keyword.get(opts, :overrides, []),
         :ok <- Sources.validate_overrides(sources, extra),
         {:ok, instructions} <- fetch_instructions(sources, opts),
         overrides = merge_overrides(sources, extra),
         {:ok, env_opts} <- environment_options(sources.env, overrides),
         session_opts = merge_sources(sources.file_options, env_opts, overrides),
         {:ok, session_opts} <- default_missing_model(session_opts, sources.providers),
         session_opts = default_session_titles(session_opts),
         session_opts = default_compile_gate(session_opts, sources.home),
         {:ok, config} <-
           session_opts
           |> Keyword.put(:providers, sources.providers)
           |> build_from_files(
             file_options(sources.file_options, env_opts, overrides),
             sources.layers
           ) do
      Prompt.assemble(config, sources, Keyword.get(session_opts, :system_prompt), instructions)
    end
  end

  defp fetch_instructions(sources, opts) do
    case Keyword.get(opts, :instructions, sources.instructions) do
      false -> {:ok, false}
      true when sources.instructions -> {:ok, true}
      other -> {:error, {:invalid_option, :instructions, other}}
    end
  end

  defp merge_overrides(%Sources{overrides: overrides, catalog_hooks: nil}, extra),
    do: Keyword.merge(overrides, extra)

  defp merge_overrides(%Sources{overrides: overrides, catalog_hooks: hooks}, extra),
    do: overrides |> Keyword.merge(extra) |> Keyword.put(:hooks, hooks)

  @doc """
  Resolves and validates explicit session configuration.

  `:providers` and a canonical `:model` reference such as
  `"openai-codex/gpt-5.5"` are required. `:providers` lists
  `Tackle.Lib.LLM.Provider` structs or adapter modules, which stand for their
  default providers; the model reference's prefix names a provider id. Each
  selection carries its provider's settings to the adapter, so they survive
  model changes. Optional `:thinking` is normalized into adapter reasoning
  options. Optional `:watchdog` enables the command watchdog; see
  `Tackle.Config.Watchdog`.
  Optional `:narration` enables the narrator for delegated runs; see
  `Tackle.Config.Narration`.

  Optional `:decision_model` is the session's default decision model reference,
  such as `"ollama/tev1:4b"`, resolved eagerly through
  `Tackle.Lib.Decision.select/2`. When any provider's adapter implements the
  decision contract, the session context gets `:decisions` — `%{providers:
  decision_providers, options: [], default_model: ref | nil}` — for tools that
  classify with them, such as the workflow tool's `tackle.classify`. A `:decisions`
  entry the host already put in `:context` is kept as given.

  Optional `:review` sets defaults for code reviews requested from the
  session: per-stage models, thinking levels, and step limits, which findings
  to show, and which built-in rules apply; see `Tackle.Review.Settings`.
  The session context gets them under `:review_settings`, unless the host
  already put a `:review_settings` entry there.

  Optional `:compile_gate` turns on the Elixir compile gate,
  `Tackle.Elixir.CompileGate`, with `Tackle.Elixir.CompileGate.Settings`
  (`false` or absent leaves it off, also in `load/1`). Agent
  states built by `to_agent_state/2` then carry the hook after the configured
  hooks and the settings under the context key `:compile_gate`, unless the host
  already put a `:compile_gate` entry there.

  Optional `:agents` maps subagent profile names to `t:agent_settings/0`,
  which `Tackle.Coding` applies over the profiles' own `model` and `thinking`.
  Model references are resolved eagerly, so unavailable models are errors even
  for profile names that no discovered profile uses.

  `:tools` (default `Tackle.Tools.default/0`) are checked as
  `Tackle.Lib.Tool.Registry.new/1` would check them when the session starts:
  `{:error, {:invalid_tool, tool, reason}}` for a value that is not a tool
  module, missing callbacks, or an invalid schema, and
  `{:invalid_tool_name, name}` or `{:duplicate_tool_name, name}`. `:hooks`
  must implement a hook callback (`Tackle.Lib.Hook.hook?/1`), or
  `{:error, {:invalid_hook, hook, :no_hook_callbacks}}`. Without a
  `:system_prompt`, the configuration gets `Tackle.SystemPrompt.default/1`.

  A malformed option list is `{:error, {:invalid_options, opts}}`,
  `{:error, {:duplicate_option, key}}`, or `{:error, {:unknown_options, keys}}`.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) do
    case build(opts) do
      {:ok, %__MODULE__{system_prompt: nil} = config} ->
        {:ok, %{config | system_prompt: SystemPrompt.default(config.tools)}}

      {:error, _option, reason} ->
        {:error, reason}

      result ->
        result
    end
  end

  # `new/1`, except that the system prompt stays `nil` unless given, since
  # `from_sources/2` builds its own, and that an error of an option a configuration
  # file can set is `{:error, option, reason}`, so `from_sources/2` can name the file.
  defp build(opts) do
    with :ok <- Options.validate_list(opts, @option_keys, @new_option_errors),
         {:ok, opts} <- normalize_thinking_option(opts),
         {:ok, providers} <- fetch_providers(opts),
         {:ok, model_ref} <- tag(fetch_model_ref(opts), :model),
         {:ok, llm} <- tag(LLM.select(providers, model_ref), :model),
         {:ok, session_titles} <-
           tag(SessionTitles.new(Keyword.get(opts, :session_titles), providers), :session_titles),
         {:ok, watchdog} <- tag(Watchdog.new(Keyword.get(opts, :watchdog), providers), :watchdog),
         {:ok, narration} <-
           tag(Narration.new(Keyword.get(opts, :narration), providers), :narration),
         {:ok, decision_model} <-
           tag(
             resolve_decision_model(Keyword.get(opts, :decision_model), providers),
             :decision_model
           ),
         {:ok, review} <- tag(ReviewSettings.new(Keyword.get(opts, :review), providers), :review),
         {:ok, compile_gate} <-
           tag(resolve_compile_gate(Keyword.get(opts, :compile_gate)), :compile_gate),
         :ok <- tag(validate_agents(Keyword.get(opts, :agents, %{}), providers), :agents),
         {:ok, tools} <- validate_tools(Keyword.get(opts, :tools, Tackle.Tools.default())),
         {:ok, hooks} <- validate_hooks(Keyword.get(opts, :hooks, [])),
         :ok <- validate_optional_string(:system_prompt, Keyword.get(opts, :system_prompt)),
         :ok <- Options.validate_context(Keyword.get(opts, :context, %{})),
         :ok <- validate_iteration_limit(Keyword.get(opts, :max_iterations, :infinity)),
         :ok <- validate_keyword_option(:llm_opts, Keyword.get(opts, :llm_opts, [])),
         :ok <- validate_reserved_llm_options(Keyword.get(opts, :llm_opts, [])),
         :ok <- validate_id_generator(Keyword.get(opts, :id_generator, &ID.uuid4/0)),
         :ok <- validate_boolean(:llm_stream, Keyword.get(opts, :llm_stream, false)),
         {:ok, retry} <- Retry.new(Keyword.get(opts, :retry)),
         {:ok, compaction} <- resolve_compaction(Keyword.get(opts, :compaction)) do
      {:ok,
       %__MODULE__{
         providers: providers,
         model_ref: model_ref,
         llm: llm,
         tools: tools,
         hooks: hooks,
         system_prompt: Keyword.get(opts, :system_prompt),
         context:
           opts
           |> Keyword.get(:context, %{})
           |> put_decisions(providers, decision_model)
           |> put_review(review),
         max_iterations: Keyword.get(opts, :max_iterations, :infinity),
         llm_opts: Keyword.get(opts, :llm_opts, []),
         id_generator: Keyword.get(opts, :id_generator, &ID.uuid4/0),
         llm_stream: Keyword.get(opts, :llm_stream, false),
         retry: retry,
         compaction: compaction,
         session_titles: session_titles,
         watchdog: watchdog,
         narration: narration,
         agents: Keyword.get(opts, :agents, %{}),
         compile_gate: compile_gate
       }}
    end
  end

  defp tag({:error, reason}, option), do: {:error, option, reason}
  defp tag(result, _option), do: result

  @doc """
  Changes settings of a built configuration with the checks `new/1` applies.

  The one way to change a `t:t/0` after it is built; the struct's fields are
  not meant to be set directly. Options:

    * `:model` - a canonical model reference, selected from the
      configuration's own providers.
    * `:thinking` - a thinking level (`Tackle.Lib.Thinking.levels/0`), set in
      `llm_opts` after any given `:llm_opts`.
    * `:max_iterations` - a positive integer or `:infinity`.
    * `:context` - entries merged into the context; the result is checked
      like `new/1`'s `:context`, including its `:executor`.
    * `:llm_opts` - adapter options merged into `llm_opts`; like `new/1`, they
      may not carry credentials.

  Any other option is `{:error, {:unknown_update_options, keys}}`, a repeated
  one `{:error, {:duplicate_update_option, key}}`, and an option list that is
  not a keyword list `{:error, {:invalid_update_options, opts}}`.
  """
  @spec update(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def update(%__MODULE__{} = config, opts) do
    with :ok <- Options.validate_list(opts, @update_option_keys, @update_option_errors),
         {:ok, model_ref} <- fetch_model_ref(model: Keyword.get(opts, :model, config.model_ref)),
         {:ok, llm} <- LLM.select(config.providers, model_ref),
         {:ok, context} <- updated_context(config.context, opts),
         {:ok, llm_opts} <- updated_llm_opts(config.llm_opts, opts),
         max_iterations = Keyword.get(opts, :max_iterations, config.max_iterations),
         :ok <- validate_iteration_limit(max_iterations) do
      {:ok,
       %{
         config
         | model_ref: model_ref,
           llm: llm,
           context: context,
           llm_opts: llm_opts,
           max_iterations: max_iterations
       }}
    end
  end

  @doc """
  Builds the initial library state for a configured session.

  The only option is `:session_id`; any other option raises
  `ArgumentError`. Credentials reach the adapters through `llm_opts`, where
  `Tackle.Session` puts its credential store.
  """
  @spec to_agent_state(t(), keyword()) :: Tackle.Lib.State.t()
  def to_agent_state(%__MODULE__{} = config, harness_opts \\ []) do
    validate_agent_state_options!(harness_opts)

    Tackle.Lib.new(
      llm: config.llm,
      tools: config.tools,
      hooks: compile_gate_hooks(config.hooks, config.compile_gate),
      system_prompt: config.system_prompt,
      context: put_compile_gate(config.context, config.compile_gate),
      max_iterations: config.max_iterations,
      tool_policy: Policy.concurrent(),
      llm_opts: config.llm_opts,
      id_generator: config.id_generator,
      session_id: Keyword.get(harness_opts, :session_id),
      retry: config.retry,
      compaction: config.compaction
    )
  end

  # An invalid value that a configuration file set is reported as
  # `{:config_file, path, reason}`. When both files set the option, the user
  # file is named if its value fails on its own, as it does in a directory
  # without a project file; otherwise the project file made it fail.
  defp build_from_files(opts, file_options, layers) do
    case build(opts) do
      {:error, option, reason} ->
        if option in file_options,
          do: {:error, file_error(opts, option, reason, layers)},
          else: {:error, reason}

      result ->
        result
    end
  end

  # The options whose values come from the configuration files.
  defp file_options(file_opts, env_opts, overrides),
    do: Keyword.keys(file_opts) -- Keyword.keys(env_opts ++ overrides)

  defp file_error(opts, option, reason, layers) do
    case Enum.filter(layers, fn {_path, layer_opts} -> Keyword.has_key?(layer_opts, option) end) do
      [] ->
        reason

      [{path, _opts}] ->
        {:config_file, path, reason}

      [{user_path, user_opts}, {project_path, _opts}] ->
        case build(Keyword.put(opts, option, Keyword.fetch!(user_opts, option))) do
          {:error, ^option, user_reason} -> {:config_file, user_path, user_reason}
          _valid -> {:config_file, project_path, reason}
        end
    end
  end

  defp validate_agent_state_options!(opts) do
    unless is_list(opts) and Keyword.keyword?(opts) and Keyword.keys(opts) -- [:session_id] == [] do
      raise ArgumentError,
            "Tackle.Config.to_agent_state/2 accepts only :session_id, got: #{inspect(opts)}"
    end
  end

  defp updated_context(context, opts) do
    case Keyword.fetch(opts, :context) do
      {:ok, entries} when is_map(entries) ->
        context = Map.merge(context, entries)
        with :ok <- Options.validate_context(context), do: {:ok, context}

      {:ok, entries} ->
        {:error, {:invalid_option, :context, entries}}

      :error ->
        {:ok, context}
    end
  end

  # Only the given options are checked for credentials: a session's own
  # `llm_opts` carry its credential store.
  defp updated_llm_opts(llm_opts, opts) do
    given = Keyword.get(opts, :llm_opts, [])

    with :ok <- validate_keyword_option(:llm_opts, given),
         :ok <- validate_reserved_llm_options(given) do
      llm_opts = Keyword.merge(llm_opts, given)

      case Keyword.fetch(opts, :thinking) do
        {:ok, level} -> Thinking.put_llm_opts(llm_opts, level)
        :error -> {:ok, llm_opts}
      end
    end
  end

  defp normalize_thinking_option(opts) do
    case Keyword.fetch(opts, :thinking) do
      {:ok, level} -> normalize_thinking_level(opts, level)
      :error -> {:ok, opts}
    end
  end

  defp normalize_thinking_level(opts, level) do
    llm_opts = Keyword.get(opts, :llm_opts, [])

    with true <- Keyword.keyword?(llm_opts),
         {:ok, llm_opts} <- tag(Thinking.put_llm_opts(llm_opts, level), :thinking) do
      {:ok, opts |> Keyword.delete(:thinking) |> Keyword.put(:llm_opts, llm_opts)}
    else
      false -> {:error, {:invalid_option, :llm_opts, llm_opts}}
      error -> error
    end
  end

  # Each setting takes the value of the first source that sets it: overrides,
  # environment, then the files. Thinking is set by an override's `:thinking`
  # or its `llm_opts[:reasoning_effort]`, which `new/1` would otherwise replace
  # with a lower source's `:thinking`.
  defp merge_sources(file_opts, env_opts, overrides) do
    session_opts = file_opts |> Keyword.merge(env_opts) |> Keyword.merge(overrides)

    if override_thinking?(overrides) and not Keyword.has_key?(overrides, :thinking),
      do: Keyword.delete(session_opts, :thinking),
      else: session_opts
  end

  defp override_thinking?(overrides) do
    llm_opts = Keyword.get(overrides, :llm_opts, [])

    Keyword.has_key?(overrides, :thinking) or
      (is_list(llm_opts) and Keyword.keyword?(llm_opts) and
         Keyword.has_key?(llm_opts, :reasoning_effort))
  end

  defp default_missing_model(session_opts, providers) do
    if Keyword.has_key?(session_opts, :model) do
      {:ok, session_opts}
    else
      with {:ok, model_ref} <- Tackle.Plugins.default_model_ref(providers) do
        {:ok, Keyword.put(session_opts, :model, model_ref)}
      end
    end
  end

  # Codex-style automatic titles are on by default for the harness loader; an
  # explicit `session_titles` entry (including `false`) in `config.json`, the
  # environment, or the overrides wins. `new/1` alone treats the option as
  # absent, so embedding hosts opt into the extra LLM call.
  defp default_session_titles(session_opts),
    do: Keyword.put_new(session_opts, :session_titles, [])

  # The compile gate is off by default. When the configuration turns it on, the
  # harness loader logs its decisions under the Tackle home unless a log path
  # was given.
  defp default_compile_gate(session_opts, home) do
    log_path = Path.join([home, "logs", "compile_gate.jsonl"])

    case Keyword.get(session_opts, :compile_gate) do
      opts when is_list(opts) ->
        Keyword.put(session_opts, :compile_gate, Keyword.put_new(opts, :log_path, log_path))

      _absent_false_or_settings ->
        session_opts
    end
  end

  # Only a variable whose setting no override replaces is read, so an invalid
  # one fails the load only when it would be used.
  defp environment_options(env, overrides) do
    with {:ok, model_opts} <- environment_model_options(env, overrides),
         {:ok, thinking_opts} <- environment_thinking_options(env, overrides) do
      {:ok, model_opts ++ thinking_opts}
    end
  end

  defp environment_model_options(env, overrides) do
    if Keyword.has_key?(overrides, :model),
      do: {:ok, []},
      else: environment_model_options(env)
  end

  defp environment_thinking_options(env, overrides) do
    if override_thinking?(overrides),
      do: {:ok, []},
      else: environment_thinking_options(env)
  end

  defp environment_model_options(env) do
    case Map.get(env, "TACKLE_MODEL") do
      nil -> {:ok, []}
      "" -> {:ok, []}
      model when is_binary(model) -> {:ok, [model: model]}
      _model -> {:error, {:invalid_environment, "TACKLE_MODEL"}}
    end
  end

  defp environment_thinking_options(env) do
    case Map.get(env, "TACKLE_THINKING") do
      nil ->
        {:ok, []}

      "" ->
        {:ok, []}

      level when is_binary(level) ->
        case Thinking.validate(level) do
          :ok -> {:ok, [thinking: level]}
          {:error, _reason} -> {:error, {:invalid_environment, "TACKLE_THINKING"}}
        end

      _level ->
        {:error, {:invalid_environment, "TACKLE_THINKING"}}
    end
  end

  defp fetch_providers(opts) do
    case Keyword.fetch(opts, :providers) do
      {:ok, providers} when is_list(providers) and providers != [] -> Provider.expand(providers)
      {:ok, providers} -> {:error, {:invalid_option, :providers, providers}}
      :error -> {:error, {:missing_option, :providers}}
    end
  end

  defp fetch_model_ref(opts) do
    case Keyword.fetch(opts, :model) do
      {:ok, model_ref} when is_binary(model_ref) -> {:ok, model_ref}
      {:ok, model_ref} -> {:error, {:invalid_option, :model, model_ref}}
      :error -> {:error, {:missing_option, :model}}
    end
  end

  # The checks `Tackle.Lib.Tool.Registry.new/1` makes when the session starts,
  # as result tuples.
  defp validate_tools(tools) when is_list(tools) do
    Enum.reduce_while(tools, {:ok, MapSet.new()}, fn tool, {:ok, names} ->
      case validate_tool(tool, names) do
        {:ok, name} -> {:cont, {:ok, MapSet.put(names, name)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _names} -> {:ok, tools}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_tools(tools), do: {:error, {:invalid_option, :tools, tools}}

  defp validate_tool(tool, names) do
    with :ok <- validate_tool_callbacks(tool),
         :ok <- validate_tool_schema(tool, :parameters, tool.parameters_schema()),
         :ok <- validate_tool_schema(tool, :output, Tool.output_schema(tool)) do
      validate_tool_name(tool.name(), names)
    end
  end

  defp validate_tool_name(name, _names) when not is_binary(name) or name == "",
    do: {:error, {:invalid_tool_name, name}}

  defp validate_tool_name(name, names) do
    if name in names, do: {:error, {:duplicate_tool_name, name}}, else: {:ok, name}
  end

  defp validate_tool_callbacks(tool) when is_atom(tool) do
    case Tool.missing_callbacks(tool) do
      [] -> :ok
      missing -> {:error, {:invalid_tool, tool, {:missing_callbacks, missing}}}
    end
  end

  defp validate_tool_callbacks(tool), do: {:error, {:invalid_tool, tool, :not_a_module}}

  # Only keyword output schemas are Tackle.Lib's own; other output schemas
  # belong to an external validator.
  defp validate_tool_schema(_tool, :output, schema) when not is_list(schema), do: :ok

  defp validate_tool_schema(tool, kind, schema) do
    case Schema.validate_schema(schema) do
      :ok -> :ok
      {:error, message} -> {:error, {:invalid_tool, tool, {:invalid_schema, kind, message}}}
    end
  end

  defp validate_hooks(hooks) when is_list(hooks) do
    case Enum.reject(hooks, &Hook.hook?/1) do
      [] -> {:ok, hooks}
      [hook | _rest] -> {:error, {:invalid_hook, hook, :no_hook_callbacks}}
    end
  end

  defp validate_hooks(hooks), do: {:error, {:invalid_option, :hooks, hooks}}

  # Compaction is enabled by default in the root harness; the trigger policy is
  # inert for models whose declared window cannot hold the reserves (see
  # `Tackle.Lib.Compaction.Policy`). Pass `compaction: false` to disable it,
  # which leaves the resolved config `nil`, as `Tackle.Lib.State` expects.
  defp resolve_compaction(nil), do: CompactionConfig.new([])
  defp resolve_compaction(%CompactionConfig{} = config), do: CompactionConfig.new(config)
  defp resolve_compaction(false), do: {:ok, nil}
  defp resolve_compaction(opts) when is_list(opts), do: CompactionConfig.new(opts)
  defp resolve_compaction(other), do: {:error, {:invalid_option, :compaction, other}}

  defp resolve_decision_model(nil, _providers), do: {:ok, nil}

  defp resolve_decision_model(model_ref, providers) when is_binary(model_ref),
    do: Decision.select(providers, model_ref)

  defp resolve_decision_model(other, _providers),
    do: {:error, {:invalid_option, :decision_model, other}}

  defp validate_agents(agents, providers) when is_map(agents) do
    Enum.reduce_while(agents, :ok, fn {name, settings}, :ok ->
      case validate_agent_settings(name, settings, providers) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:invalid_agent_settings, name, reason}}}
      end
    end)
  end

  defp validate_agents(agents, _providers), do: {:error, {:invalid_option, :agents, agents}}

  defp validate_agent_settings(name, settings, providers) do
    cond do
      not is_binary(name) or name == "" ->
        {:error, :invalid_name}

      not is_map(settings) or Map.keys(settings) -- @agent_setting_keys != [] ->
        {:error, {:invalid_settings, settings}}

      true ->
        with :ok <- validate_agent_model(settings, providers) do
          validate_agent_thinking(settings)
        end
    end
  end

  defp validate_agent_model(%{model: model_ref}, providers) when is_binary(model_ref) do
    with {:ok, _selection} <- LLM.select(providers, model_ref), do: :ok
  end

  defp validate_agent_model(%{model: model_ref}, _providers),
    do: {:error, {:invalid_option, :model, model_ref}}

  defp validate_agent_model(_settings, _providers), do: :ok

  defp validate_agent_thinking(%{thinking: level}), do: Thinking.validate(level)
  defp validate_agent_thinking(_settings), do: :ok

  # Tools reach decision models only through the session context. Only
  # providers whose adapter implements the decision contract are granted; each
  # selection carries its provider's settings to the adapter.
  defp put_decisions(%{decisions: _host_grant} = context, _providers, _default), do: context

  defp put_decisions(context, providers, default) do
    case Enum.filter(providers, &Decision.decision_adapter?(&1.adapter)) do
      [] ->
        context

      decision_providers ->
        Map.put(context, :decisions, %{
          providers: decision_providers,
          options: [],
          default_model: default && default.ref
        })
    end
  end

  defp resolve_compile_gate(nil), do: {:ok, nil}
  defp resolve_compile_gate(value), do: CompileGateSettings.new(value)

  defp compile_gate_hooks(hooks, nil), do: hooks

  defp compile_gate_hooks(hooks, %CompileGateSettings{}) do
    if CompileGate in hooks, do: hooks, else: Enum.reverse([CompileGate | Enum.reverse(hooks)])
  end

  defp put_compile_gate(context, nil), do: context
  defp put_compile_gate(%{compile_gate: _host_settings} = context, _settings), do: context
  defp put_compile_gate(context, settings), do: Map.put(context, :compile_gate, settings)

  defp put_review(context, nil), do: context
  defp put_review(%{review_settings: _host_settings} = context, _review), do: context

  defp put_review(context, %ReviewSettings{} = review),
    do: Map.put(context, :review_settings, review)

  defp validate_optional_string(_name, nil), do: :ok
  defp validate_optional_string(_name, value) when is_binary(value), do: :ok
  defp validate_optional_string(name, value), do: {:error, {:invalid_option, name, value}}

  defp validate_iteration_limit(:infinity), do: :ok
  defp validate_iteration_limit(value) when is_integer(value) and value > 0, do: :ok
  defp validate_iteration_limit(value), do: {:error, {:invalid_option, :max_iterations, value}}

  defp validate_keyword_option(name, value) when is_list(value) do
    if Keyword.keyword?(value), do: :ok, else: {:error, {:invalid_option, name, value}}
  end

  defp validate_keyword_option(name, value), do: {:error, {:invalid_option, name, value}}

  defp validate_reserved_llm_options(opts) do
    case find_reserved_llm_option(opts) do
      nil -> :ok
      option -> {:error, {:reserved_llm_option, option}}
    end
  end

  defp find_reserved_llm_option(values) when is_list(values) do
    Enum.find_value(values, fn
      {key, value} ->
        if reserved_llm_option?(key), do: key, else: find_reserved_llm_option(value)

      value ->
        find_reserved_llm_option(value)
    end)
  end

  defp find_reserved_llm_option(%{} = values) do
    Enum.find_value(values, fn {key, value} ->
      if reserved_llm_option?(key), do: key, else: find_reserved_llm_option(value)
    end)
  end

  defp find_reserved_llm_option(_value), do: nil

  defp reserved_llm_option?(key) when is_atom(key) do
    key |> Atom.to_string() |> then(&MapSet.member?(@reserved_llm_option_names, &1))
  end

  defp reserved_llm_option?(key) when is_binary(key) do
    key |> String.downcase() |> then(&MapSet.member?(@reserved_llm_option_names, &1))
  end

  defp reserved_llm_option?(_key), do: false

  defp validate_id_generator(generator) when is_function(generator, 0), do: :ok
  defp validate_id_generator(generator), do: {:error, {:invalid_option, :id_generator, generator}}

  defp validate_boolean(_name, value) when is_boolean(value), do: :ok
  defp validate_boolean(name, value), do: {:error, {:invalid_option, name, value}}
end
