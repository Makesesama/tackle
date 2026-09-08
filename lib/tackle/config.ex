defmodule Tackle.Config do
  @moduledoc """
  Validated, frontend-independent configuration for one Tackle session.

  `new/1` is the pure validation boundary for already-resolved options. `load/1`
  applies the harness configuration precedence before passing those options to
  `new/1`; it never resolves module names from file or environment data.
  """

  alias Tackle.Config.File, as: ConfigFile
  alias Tackle.Lib.ID
  alias Tackle.Lib.LLM
  alias Tackle.Lib.LLM.Selection
  alias Tackle.Lib.Tool.Adapters.Web, as: ToolAdapter
  alias Tackle.Lib.Tool.Policy
  alias Tackle.Lib.Tool.Registry, as: ToolRegistry
  alias Tackle.SystemPrompt
  alias Tackle.Thinking

  @loader_option_keys [:available_adapters, :cwd, :env, :overrides]
  @reconfigure_option_keys [:model, :thinking]

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
    :adapters,
    :model,
    :tools,
    :hooks,
    :system_prompt,
    :context,
    :max_iterations,
    :tool_policy,
    :thinking,
    :llm_opts,
    :prompt_renderer,
    :prompt_renderer_opts,
    :id_generator,
    :llm_stream
  ]

  @enforce_keys [:adapters, :model_ref, :llm]
  defstruct adapters: [],
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
            llm_stream: false

  @type t :: %__MODULE__{
          adapters: [module()],
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
          llm_stream: boolean()
        }

  @doc """
  Loads session configuration from defaults, `config.json`, environment, and
  explicit overrides, in that order.

  The supplied `:available_adapters` are executable modules chosen by the
  harness distribution. Configuration data can select their declared model
  references but cannot name or load modules. Tests and embedding hosts may
  supply an `:env` map; normal callers use the process environment. `:cwd`
  selects the working directory used for prompt discovery and built-in tools.
  """
  @spec load(keyword()) :: {:ok, t()} | {:error, term()}
  def load(opts) when is_list(opts) do
    with :ok <- validate_keyword(opts),
         :ok <- validate_loader_options(opts),
         {:ok, adapters} <- fetch_available_adapters(opts),
         {:ok, overrides} <- fetch_overrides(opts),
         {:ok, env} <- fetch_environment(opts),
         {:ok, config_path} <- Tackle.Paths.config_file(env: env),
         {:ok, file_opts} <- ConfigFile.load(config_path),
         {:ok, env_opts} <- environment_options(env),
         {:ok, session_opts} <- default_missing_model(file_opts, env_opts, overrides, adapters),
         {:ok, config} <- session_opts |> Keyword.put(:adapters, adapters) |> new(),
         {:ok, cwd} <- fetch_cwd(opts, config.context),
         {:ok, config} <-
           load_system_prompt(
             config,
             Keyword.get(session_opts, :system_prompt),
             cwd,
             Path.dirname(config_path)
           ) do
      {:ok, config}
    end
  end

  def load(opts), do: {:error, {:invalid_config_loader_options, opts}}

  @doc """
  Resolves and validates explicit session configuration.

  `:adapters` and a canonical `:model` reference such as
  `"openai-codex/gpt-5.5"` are required. Optional `:thinking` is normalized into
  adapter reasoning options.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    with :ok <- validate_keyword(opts),
         :ok <- validate_known_options(opts),
         {:ok, opts} <- normalize_thinking_option(opts),
         {:ok, adapters} <- fetch_adapters(opts),
         {:ok, model_ref} <- fetch_model_ref(opts),
         {:ok, llm} <- LLM.select(adapters, model_ref),
         {:ok, tools} <- validate_tools(Keyword.get(opts, :tools, Tackle.Tools.default())),
         {:ok, hooks} <- validate_modules(:hooks, Keyword.get(opts, :hooks, [])),
         :ok <- validate_optional_string(:system_prompt, Keyword.get(opts, :system_prompt)),
         :ok <- validate_map(:context, Keyword.get(opts, :context, %{})),
         :ok <- validate_iteration_limit(Keyword.get(opts, :max_iterations, :infinity)),
         :ok <- validate_tool_policy(Keyword.get(opts, :tool_policy, Policy.default())),
         :ok <- validate_keyword_option(:llm_opts, Keyword.get(opts, :llm_opts, [])),
         :ok <- validate_reserved_llm_options(Keyword.get(opts, :llm_opts, [])),
         :ok <-
           validate_keyword_option(
             :prompt_renderer_opts,
             Keyword.get(opts, :prompt_renderer_opts, [])
           ),
         :ok <- validate_prompt_renderer(Keyword.get(opts, :prompt_renderer)),
         :ok <- validate_id_generator(Keyword.get(opts, :id_generator, &ID.uuid4/0)),
         :ok <- validate_boolean(:llm_stream, Keyword.get(opts, :llm_stream, false)) do
      {:ok,
       %__MODULE__{
         adapters: adapters,
         model_ref: model_ref,
         llm: llm,
         tools: tools,
         hooks: hooks,
         system_prompt:
           Keyword.get_lazy(opts, :system_prompt, fn -> SystemPrompt.default(tools) end),
         context: Keyword.get(opts, :context, %{}),
         max_iterations: Keyword.get(opts, :max_iterations, :infinity),
         tool_policy: Keyword.get(opts, :tool_policy, Policy.default()),
         llm_opts: Keyword.get(opts, :llm_opts, []),
         prompt_renderer: Keyword.get(opts, :prompt_renderer),
         prompt_renderer_opts: Keyword.get(opts, :prompt_renderer_opts, []),
         id_generator: Keyword.get(opts, :id_generator, &ID.uuid4/0),
         llm_stream: Keyword.get(opts, :llm_stream, false)
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
         {:ok, llm} <- LLM.select(config.adapters, model_ref),
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
      id_generator: config.id_generator
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
      {:ok, level} ->
        llm_opts = Keyword.get(opts, :llm_opts, [])

        if Keyword.keyword?(llm_opts) do
          with {:ok, llm_opts} <- Thinking.put_llm_opts(llm_opts, level) do
            {:ok, opts |> Keyword.delete(:thinking) |> Keyword.put(:llm_opts, llm_opts)}
          end
        else
          {:error, {:invalid_option, :llm_opts, llm_opts}}
        end

      :error ->
        {:ok, opts}
    end
  end

  defp reconfigured_llm_opts(llm_opts, opts) do
    case Keyword.fetch(opts, :thinking) do
      {:ok, level} -> Thinking.put_llm_opts(llm_opts, level)
      :error -> {:ok, llm_opts}
    end
  end

  defp default_missing_model(file_opts, env_opts, overrides, adapters) do
    session_opts =
      file_opts
      |> Keyword.merge(env_opts)
      |> Keyword.merge(overrides)

    if Keyword.has_key?(session_opts, :model) do
      {:ok, session_opts}
    else
      with {:ok, model_ref} <- Tackle.Plugins.default_model_ref(adapters) do
        {:ok, Keyword.put(session_opts, :model, model_ref)}
      end
    end
  end

  defp fetch_available_adapters(opts) do
    case Keyword.fetch(opts, :available_adapters) do
      {:ok, adapters} when is_list(adapters) and adapters != [] -> {:ok, adapters}
      {:ok, adapters} -> {:error, {:invalid_option, :available_adapters, adapters}}
      :error -> Tackle.Plugins.available_adapters()
    end
  end

  defp fetch_overrides(opts) do
    overrides = Keyword.get(opts, :overrides, [])

    cond do
      not Keyword.keyword?(overrides) ->
        {:error, {:invalid_option, :overrides}}

      Keyword.has_key?(overrides, :adapters) ->
        {:error, {:reserved_override, :adapters}}

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

  defp context_cwd(context) do
    Map.get(context, :cwd) || Map.get(context, "cwd") || File.cwd()
  end

  defp normalize_cwd({:ok, cwd}), do: normalize_cwd(cwd)
  defp normalize_cwd({:error, reason}), do: {:error, {:cwd_unavailable, reason}}
  defp normalize_cwd(cwd) when is_binary(cwd), do: validate_cwd(Path.expand(cwd))
  defp normalize_cwd(cwd), do: {:error, {:invalid_option, :cwd, cwd}}

  defp validate_cwd(cwd) do
    if File.dir?(cwd), do: {:ok, cwd}, else: {:error, {:invalid_option, :cwd, cwd}}
  end

  defp load_system_prompt(config, base, cwd, home) do
    context = Map.put(config.context, :cwd, cwd)

    case SystemPrompt.build(base: base, cwd: cwd, home: home, tools: config.tools) do
      {:ok, prompt} -> {:ok, %{config | context: context, system_prompt: prompt}}
      {:error, reason} -> {:error, reason}
    end
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

  defp fetch_adapters(opts) do
    case Keyword.fetch(opts, :adapters) do
      {:ok, adapters} when is_list(adapters) and adapters != [] -> {:ok, adapters}
      {:ok, adapters} -> {:error, {:invalid_option, :adapters, adapters}}
      :error -> {:error, {:missing_option, :adapters}}
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
    validated = ToolAdapter.wrap(tools)
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

  defp validate_optional_string(_name, nil), do: :ok
  defp validate_optional_string(_name, value) when is_binary(value), do: :ok
  defp validate_optional_string(name, value), do: {:error, {:invalid_option, name, value}}

  defp validate_map(_name, value) when is_map(value), do: :ok
  defp validate_map(name, value), do: {:error, {:invalid_option, name, value}}

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

  defp validate_tool_policy(%Policy{}), do: :ok
  defp validate_tool_policy(policy), do: {:error, {:invalid_option, :tool_policy, policy}}

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
