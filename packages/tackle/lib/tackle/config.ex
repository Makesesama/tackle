defmodule Tackle.Config do
  @moduledoc """
  Validated, frontend-independent configuration for one Tackle session.

  `new/1` is the pure validation boundary for already-resolved options. `load/1`
  applies the harness configuration precedence before passing those options to
  `new/1`; it never resolves module names from file or environment data.
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

  require Logger

  alias Tackle.Config.File, as: ConfigFile
  alias Tackle.Config.Narration
  alias Tackle.Config.SessionTitles
  alias Tackle.Config.Watchdog
  alias Tackle.Elixir.CompileGate
  alias Tackle.Elixir.CompileGate.Settings, as: CompileGateSettings
  alias Tackle.Executor
  alias Tackle.Lib.Compaction.Config, as: CompactionConfig
  alias Tackle.Lib.Decision
  alias Tackle.Lib.ID
  alias Tackle.Lib.LLM
  alias Tackle.Lib.LLM.Provider
  alias Tackle.Lib.LLM.Selection
  alias Tackle.Lib.Retry
  alias Tackle.Lib.Thinking
  alias Tackle.Lib.Tool
  alias Tackle.Lib.Tool.Policy
  alias Tackle.Lib.Tool.Registry, as: ToolRegistry
  alias Tackle.Plugins.Catalog
  alias Tackle.ProjectFiles
  alias Tackle.Review.Settings, as: ReviewSettings
  alias Tackle.Skills
  alias Tackle.Skills.Skill
  alias Tackle.SystemPrompt
  alias Tackle.Tools.LoadSkill

  @loader_option_keys [
    :accounts,
    :available_adapters,
    :builtin_skills,
    :catalog,
    :cwd,
    :env,
    :instructions,
    :overrides
  ]
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

  @project_config_file ".tackle/config.json"
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
            tool_policy: nil,
            llm_opts: [],
            id_generator: &ID.uuid4/0,
            llm_stream: false,
            retry: Retry.new!(),
            compaction: nil,
            session_titles: nil,
            watchdog: nil,
            narration: nil,
            decision_model: nil,
            review: nil,
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
          tool_policy: Policy.t(),
          llm_opts: keyword(),
          id_generator: ID.generator(),
          llm_stream: boolean(),
          retry: Retry.t(),
          compaction: CompactionConfig.t() | nil,
          session_titles: SessionTitles.t() | nil,
          watchdog: Watchdog.t() | nil,
          narration: Narration.t() | nil,
          decision_model: Tackle.Lib.Decision.Selection.t() | nil,
          review: ReviewSettings.t() | nil,
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
  JSON objects merged recursively, and may not declare `providers`: it selects
  models and settings among the providers the user configured.

  The supplied `:available_adapters` are executable modules chosen by the
  harness distribution. Alternatively, a trusted host can supply `:catalog`
  to select its adapter and hook modules; specifying both adapter sources, or
  overriding catalog hooks, is an error. Catalog tools are not granted by this
  option. Configuration data can select declared model references and declare
  providers of those adapters (the `config.json` `"providers"` object) but
  cannot name or load modules.

  The session's providers are merged by `Tackle.Plugins.provider_entries/1`
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
    with :ok <- validate_option_list(opts, @loader_option_keys, :load),
         {:ok, overrides} <- fetch_overrides(opts),
         :ok <- validate_override_context(overrides),
         {:ok, adapters} <- fetch_available_adapters(opts),
         {:ok, accounts} <- fetch_accounts(opts),
         {:ok, builtin_skills} <- fetch_builtin_skills(opts),
         {:ok, instructions} <- fetch_instructions(opts),
         {:ok, overrides} <- catalog_hooks(opts, overrides),
         {:ok, env} <- fetch_environment(opts),
         {:ok, cwd} <- fetch_cwd(opts, Keyword.get(overrides, :context, %{})),
         {:ok, config_path} <- Tackle.Paths.config_file(env: env),
         {:ok, project_file} <- read_project_config(cwd, overrides, config_path),
         {:ok, file_opts, layers} <- ConfigFile.load(config_path, project_file),
         {declared, file_opts} = Keyword.pop(file_opts, :providers, %{}),
         {:ok, entries} <-
           Tackle.Plugins.provider_entries(
             adapters: adapters,
             accounts: accounts,
             config_providers: declared
           ),
         providers = Enum.map(entries, & &1.provider),
         {:ok, env_opts} <- environment_options(env, overrides),
         session_opts = merge_sources(file_opts, env_opts, overrides),
         {:ok, session_opts} <- default_missing_model(session_opts, providers),
         {:ok, session_opts} <- default_session_titles(session_opts),
         session_opts = default_compile_gate(session_opts, Path.dirname(config_path)),
         {:ok, config} <-
           session_opts
           |> Keyword.put(:providers, providers)
           |> build_from_files(file_options(file_opts, env_opts, overrides), layers) do
      load_system_prompt(
        config,
        Keyword.get(session_opts, :system_prompt),
        cwd,
        Path.dirname(config_path),
        env,
        builtin_skills,
        instructions
      )
    end
  end

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

  A malformed option list is `{:error, {:invalid_options, opts}}`,
  `{:error, {:duplicate_option, key}}`, or `{:error, {:unknown_options, keys}}`.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) do
    case build(opts) do
      {:error, _option, reason} -> {:error, reason}
      result -> result
    end
  end

  # `new/1`, except that an error of an option a configuration file can set is
  # `{:error, option, reason}`, so `load/1` can name the file.
  defp build(opts) do
    with :ok <- validate_option_list(opts, @option_keys, :new),
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
         {:ok, hooks} <- validate_modules(:hooks, Keyword.get(opts, :hooks, [])),
         :ok <- validate_optional_string(:system_prompt, Keyword.get(opts, :system_prompt)),
         :ok <- validate_map(:context, Keyword.get(opts, :context, %{})),
         :ok <- validate_executor(Keyword.get(opts, :context, %{})),
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
         system_prompt:
           Keyword.get_lazy(opts, :system_prompt, fn -> SystemPrompt.default(tools) end),
         context:
           opts
           |> Keyword.get(:context, %{})
           |> put_decisions(providers, decision_model)
           |> put_review(review),
         max_iterations: Keyword.get(opts, :max_iterations, :infinity),
         tool_policy: Policy.concurrent(),
         llm_opts: Keyword.get(opts, :llm_opts, []),
         id_generator: Keyword.get(opts, :id_generator, &ID.uuid4/0),
         llm_stream: Keyword.get(opts, :llm_stream, false),
         retry: retry,
         compaction: compaction,
         session_titles: session_titles,
         watchdog: watchdog,
         narration: narration,
         decision_model: decision_model,
         review: review,
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
    with :ok <- validate_option_list(opts, @update_option_keys, :update),
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
      tool_policy: config.tool_policy,
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

  # Each entry point reports a malformed option list with its own tags.
  @option_list_errors %{
    load: {:invalid_loader_options, :duplicate_loader_option, :unknown_loader_options},
    new: {:invalid_options, :duplicate_option, :unknown_options},
    update: {:invalid_update_options, :duplicate_update_option, :unknown_update_options}
  }

  defp validate_option_list(opts, known_keys, entry_point) do
    {invalid, duplicate, unknown} = Map.fetch!(@option_list_errors, entry_point)

    cond do
      not (is_list(opts) and Keyword.keyword?(opts)) ->
        {:error, {invalid, opts}}

      duplicate_key = duplicate(Keyword.keys(opts)) ->
        {:error, {duplicate, duplicate_key}}

      (unknown_keys = Keyword.keys(opts) -- known_keys) != [] ->
        {:error, {unknown, Enum.uniq(unknown_keys)}}

      true ->
        :ok
    end
  end

  defp updated_context(context, opts) do
    case Keyword.fetch(opts, :context) do
      {:ok, entries} when is_map(entries) ->
        context = Map.merge(context, entries)
        with :ok <- validate_executor(context), do: {:ok, context}

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
  defp default_session_titles(session_opts) do
    if Keyword.has_key?(session_opts, :session_titles) do
      {:ok, session_opts}
    else
      {:ok, Keyword.put(session_opts, :session_titles, [])}
    end
  end

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

  defp fetch_available_adapters(opts) do
    case {Keyword.fetch(opts, :catalog), Keyword.fetch(opts, :available_adapters)} do
      {{:ok, %Catalog{adapters: []}}, :error} -> {:error, :no_adapters_configured}
      {{:ok, %Catalog{} = catalog}, :error} -> {:ok, Catalog.adapter_modules(catalog)}
      {{:ok, %Catalog{}}, {:ok, _}} -> {:error, :conflicting_adapter_sources}
      {{:ok, value}, _} -> {:error, {:invalid_option, :catalog, value}}
      {:error, {:ok, adapters}} when is_list(adapters) and adapters != [] -> {:ok, adapters}
      {:error, {:ok, adapters}} -> {:error, {:invalid_option, :available_adapters, adapters}}
      {:error, :error} -> Tackle.Plugins.available_adapters()
    end
  end

  defp fetch_accounts(opts) do
    case Keyword.fetch(opts, :accounts) do
      {:ok, %{} = accounts} ->
        {:ok, accounts}

      {:ok, accounts} ->
        {:error, {:invalid_option, :accounts, accounts}}

      :error ->
        stored_accounts()
    end
  end

  defp stored_accounts do
    case Tackle.Auth.accounts() do
      {:ok, accounts} -> {:ok, accounts}
      {:error, reason} -> {:error, {:accounts_unavailable, reason}}
    end
  catch
    :exit, reason -> {:error, {:accounts_unavailable, reason}}
  end

  defp catalog_hooks(opts, overrides) do
    case Keyword.fetch(opts, :catalog) do
      {:ok, %Catalog{} = catalog} ->
        if Keyword.has_key?(overrides, :hooks),
          do: {:error, :conflicting_hook_sources},
          else: {:ok, Keyword.put(overrides, :hooks, Catalog.hook_modules(catalog))}

      {:ok, value} ->
        {:error, {:invalid_option, :catalog, value}}

      :error ->
        {:ok, overrides}
    end
  end

  defp fetch_overrides(opts) do
    overrides = Keyword.get(opts, :overrides, [])

    cond do
      not Keyword.keyword?(overrides) ->
        {:error, {:invalid_option, :overrides, overrides}}

      Keyword.has_key?(overrides, :providers) ->
        {:error, {:reserved_override, :providers}}

      true ->
        {:ok, overrides}
    end
  end

  # The project file and instruction files are read through the context's
  # executor, so it is validated before anything is read: a malformed one must
  # not fall back to reading the workspace unjailed.
  defp validate_override_context(overrides) do
    case Keyword.fetch(overrides, :context) do
      {:ok, context} ->
        with :ok <- validate_map(:context, context), do: validate_executor(context)

      :error ->
        :ok
    end
  end

  defp fetch_environment(opts) do
    case Keyword.get_lazy(opts, :env, &System.get_env/0) do
      %{} = env -> {:ok, env}
      env -> {:error, {:invalid_option, :env, env}}
    end
  end

  defp fetch_cwd(opts, context) do
    case Keyword.fetch(opts, :cwd) do
      {:ok, cwd} -> normalize_cwd(cwd)
      :error -> context |> context_cwd() |> normalize_cwd()
    end
  end

  defp context_cwd(%{cwd: cwd}), do: cwd
  defp context_cwd(%{"cwd" => cwd}), do: cwd
  defp context_cwd(_context), do: File.cwd()

  defp normalize_cwd({:ok, cwd}), do: normalize_cwd(cwd)
  defp normalize_cwd({:error, reason}), do: {:error, {:cwd_unavailable, reason}}
  defp normalize_cwd(cwd) when is_binary(cwd), do: validate_cwd(Path.expand(cwd))
  defp normalize_cwd(cwd), do: {:error, {:invalid_option, :cwd, cwd}}

  defp validate_cwd(cwd) do
    if File.dir?(cwd), do: {:ok, cwd}, else: {:error, {:invalid_option, :cwd, cwd}}
  end

  # The project file lives in the workspace, so it is read through the session
  # executor like `AGENTS.md`. Outside any Git repository the search can reach
  # `$TACKLE_HOME` itself, whose config.json is the user file, not a project.
  defp read_project_config(cwd, overrides, user_path) do
    files =
      ProjectFiles.new(executor: overrides |> Keyword.get(:context) |> Executor.from_context())

    case ProjectFiles.nearest_project_file(files, cwd, @project_config_file) do
      nil ->
        {:ok, nil}

      path ->
        if ProjectFiles.same_dir?(Path.dirname(path), Path.dirname(user_path)),
          do: {:ok, nil},
          else: read_project_file(files, path)
    end
  end

  defp read_project_file(files, path) do
    case ProjectFiles.read(files, path) do
      {:ok, contents} -> {:ok, {path, contents}}
      {:error, reason} -> {:error, {:config_file, path, {:unreadable, reason}}}
    end
  end

  defp load_system_prompt(config, base, cwd, home, env, builtin_skills, instructions) do
    context = Map.put(config.context, :cwd, cwd)
    executor = Executor.from_context(context)

    skills =
      if instructions,
        do:
          cwd |> discover_skills(env, executor, builtin_skills) |> Skills.available(config.tools),
        else: []

    with {:ok, tools, context} <- grant_skills(config.tools, context, skills),
         {:ok, prompt} <-
           SystemPrompt.build(
             base: base,
             cwd: cwd,
             home: home,
             tools: tools,
             skills: skills,
             executor: executor,
             instructions: instructions
           ) do
      {:ok, %{config | tools: tools, context: context, system_prompt: prompt}}
    end
  end

  # Offering a skill also grants the tool that loads it, for file and built-in
  # skills alike.
  defp grant_skills(tools, context, skills) do
    case Enum.reject(skills, & &1.disable_model_invocation) do
      [] ->
        {:ok, tools, context}

      offered ->
        with :ok <- ensure_load_skill_name_free(tools) do
          {:ok, append_load_skill(tools), Map.put(context, :skills, offered)}
        end
    end
  end

  defp append_load_skill(tools) do
    if LoadSkill in tools, do: tools, else: Enum.reverse([LoadSkill | Enum.reverse(tools)])
  end

  # The tool is granted after `validate_tools/1`, so a different tool with the
  # same name must be reported here rather than when the session starts.
  defp ensure_load_skill_name_free(tools) do
    name = LoadSkill.name()

    if Enum.any?(tools, &(&1 != LoadSkill and &1.name() == name)),
      do: {:error, {:tool_name_conflict, name}},
      else: :ok
  end

  defp fetch_instructions(opts) do
    case Keyword.get(opts, :instructions, true) do
      instructions when is_boolean(instructions) -> {:ok, instructions}
      other -> {:error, {:invalid_option, :instructions, other}}
    end
  end

  defp fetch_builtin_skills(opts) do
    skills = Keyword.get(opts, :builtin_skills, [])

    cond do
      not is_list(skills) or not Enum.all?(skills, &valid_builtin_skill?/1) ->
        {:error, {:invalid_option, :builtin_skills, skills}}

      length(Enum.uniq_by(skills, & &1.name)) != length(skills) ->
        {:error, {:duplicate_builtin_skills, skills |> Enum.map(& &1.name) |> duplicates()}}

      true ->
        {:ok, skills}
    end
  end

  # Built-in skills normally come from `Tackle.Skills.builtin/2`; this guards
  # hand-built structs that would otherwise fail later, inside the session.
  defp valid_builtin_skill?(%Skill{
         source: :builtin,
         name: name,
         description: description,
         content: content,
         requires_tools: requires_tools
       }) do
    Enum.all?([name, description, content], &(is_binary(&1) and &1 != "")) and
      is_list(requires_tools) and Enum.all?(requires_tools, &(is_binary(&1) and &1 != ""))
  end

  defp valid_builtin_skill?(_skill), do: false

  defp duplicates(names) do
    names |> Enum.frequencies() |> Enum.filter(&(elem(&1, 1) > 1)) |> Enum.map(&elem(&1, 0))
  end

  defp discover_skills(cwd, env, executor, builtins) do
    user_home = Map.get(env, "HOME") || Map.get(env, "USERPROFILE")

    discovery =
      Skills.discover(
        cwd: cwd,
        user_home: user_home,
        executor: executor,
        builtins: builtins
      )

    Enum.each(discovery.warnings, fn %{path: path, message: message} ->
      Logger.warning("skipping or adjusting skill #{path}: #{message}")
    end)

    discovery.skills
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

  defp validate_tools(tools) when is_list(tools) do
    validated = validate_tool_modules(tools)
    names = Enum.map(validated, & &1.name())

    cond do
      invalid_name = Enum.find(names, &(not is_binary(&1) or &1 == "")) ->
        {:error, {:invalid_tool_name, invalid_name}}

      duplicate_name = duplicate(names) ->
        {:error, {:duplicate_tool_name, duplicate_name}}

      true ->
        _registry = ToolRegistry.new(validated)
        {:ok, validated}
    end
  rescue
    exception -> {:error, {:invalid_tools, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:invalid_tools, {kind, reason}}}
  end

  defp validate_tools(tools), do: {:error, {:invalid_option, :tools, tools}}

  defp validate_tool_modules(tools) do
    Enum.map(tools, &validate_tool_module/1)
  end

  defp validate_tool_module(tool) when is_atom(tool) do
    case Tool.missing_callbacks(tool) do
      [] -> tool
      missing -> raise ArgumentError, missing_callbacks_message(tool, missing)
    end
  end

  defp validate_tool_module(tool) do
    raise ArgumentError, "Tackle.Config expects a list of tool modules, got: #{inspect(tool)}"
  end

  defp missing_callbacks_message(tool, missing) do
    callbacks = Enum.map_join(missing, ", ", fn {name, arity} -> "#{name}/#{arity}" end)

    "#{inspect(tool)} is not a valid Tackle.Lib.Tool; missing callbacks: " <> callbacks
  end

  defp validate_modules(name, modules) when is_list(modules) do
    case Enum.find(modules, &(not valid_module?(&1))) do
      nil -> {:ok, modules}
      module -> {:error, {:invalid_module, name, module}}
    end
  end

  defp validate_modules(name, modules), do: {:error, {:invalid_option, name, modules}}

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
    case Enum.filter(providers, &decision_provider?/1) do
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

  defp decision_provider?(%Provider{adapter: adapter}) do
    function_exported?(adapter, :decide, 2) and
      (function_exported?(adapter, :decision_models, 1) or
         function_exported?(adapter, :decision_models, 0))
  end

  defp validate_optional_string(_name, nil), do: :ok
  defp validate_optional_string(_name, value) when is_binary(value), do: :ok
  defp validate_optional_string(name, value), do: {:error, {:invalid_option, name, value}}

  defp validate_map(_name, value) when is_map(value), do: :ok
  defp validate_map(name, value), do: {:error, {:invalid_option, name, value}}

  # Tools fall back to the local executor when `context.executor` is absent, so a
  # malformed value must fail here rather than silently run unjailed.
  defp validate_executor(%{executor: {module, _config}} = context) when is_atom(module) do
    if executor_module?(module),
      do: :ok,
      else: {:error, {:invalid_option, :executor, context.executor}}
  end

  defp validate_executor(%{executor: executor}),
    do: {:error, {:invalid_option, :executor, executor}}

  defp validate_executor(_context), do: :ok

  # Optional callbacks, such as `input/3`, are not required.
  defp executor_module?(module) do
    required =
      Executor.behaviour_info(:callbacks) -- Executor.behaviour_info(:optional_callbacks)

    Code.ensure_loaded?(module) and
      Enum.all?(required, fn {name, arity} -> function_exported?(module, name, arity) end)
  end

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

  defp valid_module?(module) when is_atom(module) and not is_nil(module),
    do: Code.ensure_loaded?(module)

  defp valid_module?(_module), do: false

  defp duplicate(values) do
    Enum.reduce_while(values, MapSet.new(), fn value, seen ->
      if MapSet.member?(seen, value) do
        {:halt, value}
      else
        {:cont, MapSet.put(seen, value)}
      end
    end)
    |> case do
      %MapSet{} -> nil
      value -> value
    end
  end
end
