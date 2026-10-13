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
  alias Tackle.Executor
  alias Tackle.Lib.Compaction.Config, as: CompactionConfig
  alias Tackle.Lib.Decision
  alias Tackle.Lib.ID
  alias Tackle.Lib.LLM
  alias Tackle.Lib.LLM.Provider
  alias Tackle.Lib.LLM.Selection
  alias Tackle.Lib.Retry
  alias Tackle.Lib.Tool.Policy
  alias Tackle.Lib.Tool.Registry, as: ToolRegistry
  alias Tackle.Plugins.Catalog
  alias Tackle.Skills
  alias Tackle.Skills.Skill
  alias Tackle.SystemPrompt
  alias Tackle.Thinking
  alias Tackle.Tools.LoadSkill

  @loader_option_keys [
    :accounts,
    :available_adapters,
    :builtin_skills,
    :catalog,
    :cwd,
    :env,
    :overrides
  ]
  @reconfigure_option_keys [:model, :thinking]

  @tool_callbacks [{:name, 0}, {:description, 0}, {:parameters_schema, 0}, {:execute, 2}]

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
    :prompt_renderer,
    :prompt_renderer_opts,
    :id_generator,
    :llm_stream,
    :retry,
    :compaction,
    :session_titles,
    :watchdog,
    :narration,
    :decision_model
  ]

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
            prompt_renderer: nil,
            prompt_renderer_opts: [],
            id_generator: &ID.uuid4/0,
            llm_stream: false,
            retry: Retry.new!(),
            compaction: nil,
            session_titles: nil,
            watchdog: nil,
            narration: nil,
            decision_model: nil

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
          prompt_renderer: module() | nil,
          prompt_renderer_opts: keyword(),
          id_generator: ID.generator(),
          llm_stream: boolean(),
          retry: Retry.t(),
          compaction: CompactionConfig.t() | nil,
          session_titles: SessionTitles.t() | nil,
          watchdog: Watchdog.t() | nil,
          narration: Narration.t() | nil,
          decision_model: Tackle.Lib.Decision.Selection.t() | nil
        }

  @doc """
  Loads session configuration from defaults, `config.json`, environment, and
  explicit overrides, in that order.

  The supplied `:available_adapters` are executable modules chosen by the
  harness distribution. Alternatively, a trusted host can supply `:catalog`
  to select its adapter and hook modules; specifying both adapter sources, or
  overriding catalog hooks, is an error. Catalog tools are not granted by this
  option. Configuration data can select declared model references and declare
  providers of those adapters (the `config.json` `"providers"` object) but
  cannot name or load modules.

  The session's providers are merged by `Tackle.Plugins.merge_providers/3`
  from the adapters' default providers, the recorded accounts, and the
  `config.json` providers. `:accounts` (`t:Tackle.Plugins.accounts/0`)
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
  """
  @spec load(keyword()) :: {:ok, t()} | {:error, term()}
  def load(opts) when is_list(opts) do
    with :ok <- validate_keyword(opts),
         :ok <- validate_loader_options(opts),
         {:ok, adapters} <- fetch_available_adapters(opts),
         {:ok, accounts} <- fetch_accounts(opts),
         {:ok, builtin_skills} <- fetch_builtin_skills(opts),
         {:ok, overrides} <- fetch_overrides(opts),
         {:ok, overrides} <- catalog_hooks(opts, overrides),
         {:ok, env} <- fetch_environment(opts),
         {:ok, config_path} <- Tackle.Paths.config_file(env: env),
         {:ok, file_opts} <- ConfigFile.load(config_path),
         {declared, file_opts} = Keyword.pop(file_opts, :providers, %{}),
         {:ok, entries} <- Tackle.Plugins.merge_providers(adapters, accounts, declared),
         providers = Enum.map(entries, & &1.provider),
         {:ok, env_opts} <- environment_options(env),
         {:ok, session_opts} <- default_missing_model(file_opts, env_opts, overrides, providers),
         {:ok, session_opts} <- default_session_titles(session_opts),
         {:ok, config} <- session_opts |> Keyword.put(:providers, providers) |> new(),
         {:ok, cwd} <- fetch_cwd(opts, config.context) do
      load_system_prompt(
        config,
        Keyword.get(session_opts, :system_prompt),
        cwd,
        Path.dirname(config_path),
        env,
        builtin_skills
      )
    end
  end

  def load(opts), do: {:error, {:invalid_config_loader_options, opts}}

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
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    with :ok <- validate_keyword(opts),
         :ok <- validate_known_options(opts),
         {:ok, opts} <- normalize_thinking_option(opts),
         {:ok, providers} <- fetch_providers(opts),
         {:ok, model_ref} <- fetch_model_ref(opts),
         {:ok, llm} <- LLM.select(providers, model_ref),
         {:ok, session_titles} <-
           resolve_session_titles(Keyword.get(opts, :session_titles), providers),
         {:ok, watchdog} <- Watchdog.new(Keyword.get(opts, :watchdog), providers),
         {:ok, narration} <- Narration.new(Keyword.get(opts, :narration), providers),
         {:ok, decision_model} <-
           resolve_decision_model(Keyword.get(opts, :decision_model), providers),
         {:ok, tools} <- validate_tools(Keyword.get(opts, :tools, Tackle.Tools.default())),
         {:ok, hooks} <- validate_modules(:hooks, Keyword.get(opts, :hooks, [])),
         :ok <- validate_optional_string(:system_prompt, Keyword.get(opts, :system_prompt)),
         :ok <- validate_map(:context, Keyword.get(opts, :context, %{})),
         :ok <- validate_executor(Keyword.get(opts, :context, %{})),
         :ok <- validate_iteration_limit(Keyword.get(opts, :max_iterations, :infinity)),
         :ok <- validate_keyword_option(:llm_opts, Keyword.get(opts, :llm_opts, [])),
         :ok <- validate_reserved_llm_options(Keyword.get(opts, :llm_opts, [])),
         :ok <-
           validate_keyword_option(
             :prompt_renderer_opts,
             Keyword.get(opts, :prompt_renderer_opts, [])
           ),
         :ok <- validate_prompt_renderer(Keyword.get(opts, :prompt_renderer)),
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
           |> put_decisions(providers, decision_model),
         max_iterations: Keyword.get(opts, :max_iterations, :infinity),
         tool_policy: Policy.concurrent(),
         llm_opts: Keyword.get(opts, :llm_opts, []),
         prompt_renderer: Keyword.get(opts, :prompt_renderer),
         prompt_renderer_opts: Keyword.get(opts, :prompt_renderer_opts, []),
         id_generator: Keyword.get(opts, :id_generator, &ID.uuid4/0),
         llm_stream: Keyword.get(opts, :llm_stream, false),
         retry: retry,
         compaction: compaction,
         session_titles: session_titles,
         watchdog: watchdog,
         narration: narration,
         decision_model: decision_model
       }}
    end
  end

  def new(opts), do: {:error, {:invalid_config, opts}}

  @doc "Updates model and thinking settings for an idle configured session."
  @spec reconfigure(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def reconfigure(%__MODULE__{} = config, opts) when is_list(opts) do
    with :ok <- validate_keyword(opts),
         :ok <- validate_reconfigure_options(opts),
         {:ok, model_ref} <- reconfigured_model_ref(config, opts),
         {:ok, llm} <- LLM.select(config.providers, model_ref),
         {:ok, llm_opts} <- reconfigured_llm_opts(config.llm_opts, opts) do
      {:ok, %{config | model_ref: model_ref, llm: llm, llm_opts: llm_opts}}
    end
  end

  def reconfigure(%__MODULE__{}, opts), do: {:error, {:invalid_config, opts}}

  @doc "Builds the initial library state for a configured session."
  @spec to_agent_state(t(), keyword()) :: Tackle.Lib.State.t()
  def to_agent_state(%__MODULE__{} = config, harness_opts \\ []) do
    llm_opts =
      case Keyword.get(harness_opts, :credential_store) do
        nil -> config.llm_opts
        handle -> Keyword.put(config.llm_opts, :credential_store, handle)
      end

    Tackle.Lib.new(
      llm: config.llm,
      tools: config.tools,
      hooks: config.hooks,
      system_prompt: config.system_prompt,
      context: config.context,
      max_iterations: config.max_iterations,
      tool_policy: config.tool_policy,
      llm_opts: llm_opts,
      prompt_renderer: config.prompt_renderer,
      prompt_renderer_opts: config.prompt_renderer_opts,
      id_generator: config.id_generator,
      session_id: Keyword.get(harness_opts, :session_id),
      retry: config.retry,
      compaction: config.compaction
    )
  end

  defp validate_loader_options(opts) do
    case Keyword.keys(opts) -- @loader_option_keys do
      [] -> :ok
      unknown -> {:error, {:unknown_loader_options, Enum.uniq(unknown)}}
    end
  end

  defp validate_reconfigure_options(opts) do
    case Keyword.keys(opts) -- @reconfigure_option_keys do
      [] -> :ok
      unknown -> {:error, {:unknown_reconfigure_options, Enum.uniq(unknown)}}
    end
  end

  defp reconfigured_model_ref(config, opts) do
    fetch_model_ref(model: Keyword.get(opts, :model, config.model_ref))
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
         {:ok, llm_opts} <- Thinking.put_llm_opts(llm_opts, level) do
      {:ok, opts |> Keyword.delete(:thinking) |> Keyword.put(:llm_opts, llm_opts)}
    else
      false -> {:error, {:invalid_option, :llm_opts, llm_opts}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconfigured_llm_opts(llm_opts, opts) do
    case Keyword.fetch(opts, :thinking) do
      {:ok, level} -> Thinking.put_llm_opts(llm_opts, level)
      :error -> {:ok, llm_opts}
    end
  end

  defp default_missing_model(file_opts, env_opts, overrides, providers) do
    session_opts =
      file_opts
      |> Keyword.merge(env_opts)
      |> Keyword.merge(overrides)

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
        try do
          {:ok, Tackle.Auth.accounts()}
        catch
          :exit, reason -> {:error, {:accounts_unavailable, reason}}
        end
    end
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
        {:error, {:invalid_option, :overrides}}

      Keyword.has_key?(overrides, :providers) ->
        {:error, {:reserved_override, :providers}}

      true ->
        {:ok, overrides}
    end
  end

  defp fetch_environment(opts) do
    case Keyword.get_lazy(opts, :env, &System.get_env/0) do
      %{} = env -> {:ok, env}
      _env -> {:error, {:invalid_option, :env}}
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

  defp load_system_prompt(config, base, cwd, home, env, builtin_skills) do
    context = Map.put(config.context, :cwd, cwd)
    executor = Executor.from_context(context)

    skills =
      cwd
      |> discover_skills(env, executor, builtin_skills)
      |> Skills.available(config.tools)

    with {:ok, tools, context} <- grant_skills(config.tools, context, skills),
         {:ok, prompt} <-
           SystemPrompt.build(
             base: base,
             cwd: cwd,
             home: home,
             tools: tools,
             skills: skills,
             executor: executor
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

  defp environment_options(env) do
    with {:ok, model_opts} <- environment_model_options(env),
         {:ok, thinking_opts} <- environment_thinking_options(env) do
      {:ok, model_opts ++ thinking_opts}
    end
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

  defp validate_keyword(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, {:invalid_config, opts}}

      duplicate_key = duplicate(Keyword.keys(opts)) ->
        {:error, {:duplicate_option, duplicate_key}}

      true ->
        :ok
    end
  end

  defp validate_known_options(opts) do
    case Keyword.keys(opts) -- @option_keys do
      [] -> :ok
      unknown -> {:error, {:unknown_options, Enum.uniq(unknown)}}
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
    case missing_tool_callbacks(tool) do
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

  defp missing_tool_callbacks(tool) do
    if Code.ensure_loaded?(tool) do
      Enum.reject(@tool_callbacks, fn {name, arity} ->
        function_exported?(tool, name, arity)
      end)
    else
      @tool_callbacks
    end
  end

  defp validate_modules(name, modules) when is_list(modules) do
    case Enum.find(modules, &(not valid_module?(&1))) do
      nil -> {:ok, modules}
      module -> {:error, {:invalid_module, name, module}}
    end
  end

  defp validate_modules(name, modules), do: {:error, {:invalid_option, name, modules}}

  defp validate_prompt_renderer(nil), do: :ok

  defp validate_prompt_renderer(renderer) do
    required = [render_tools: 2, render_response_format: 1, response_schema: 1]

    if valid_module?(renderer) and
         Enum.all?(required, fn {name, arity} -> function_exported?(renderer, name, arity) end) do
      :ok
    else
      {:error, {:invalid_prompt_renderer, renderer}}
    end
  end

  # Compaction is enabled by default in the root harness; the trigger policy is
  # inert for models whose declared window cannot hold the reserves (see
  # `Tackle.Lib.Compaction.Policy`). Pass `compaction: false` to disable it.
  defp resolve_compaction(nil), do: CompactionConfig.new([])
  defp resolve_compaction(%CompactionConfig{} = config), do: CompactionConfig.new(config)
  defp resolve_compaction(false), do: CompactionConfig.new(false)
  defp resolve_compaction(opts) when is_list(opts), do: CompactionConfig.new(opts)
  defp resolve_compaction(other), do: {:error, {:invalid_option, :compaction, other}}

  defp resolve_session_titles(nil, _providers), do: {:ok, nil}
  defp resolve_session_titles(false, _providers), do: {:ok, nil}

  defp resolve_session_titles(%SessionTitles{} = config, providers),
    do: SessionTitles.new(config, providers)

  defp resolve_session_titles(opts, providers) when is_list(opts),
    do: SessionTitles.new(opts, providers)

  defp resolve_session_titles(other, _providers),
    do: {:error, {:invalid_option, :session_titles, other}}

  defp resolve_decision_model(nil, _providers), do: {:ok, nil}

  defp resolve_decision_model(model_ref, providers) when is_binary(model_ref),
    do: Decision.select(providers, model_ref)

  defp resolve_decision_model(other, _providers),
    do: {:error, {:invalid_option, :decision_model, other}}

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

  defp executor_module?(module) do
    Code.ensure_loaded?(module) and
      Enum.all?(Executor.behaviour_info(:callbacks), fn {name, arity} ->
        function_exported?(module, name, arity)
      end)
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
