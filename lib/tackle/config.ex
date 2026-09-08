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

  @loader_option_keys [:available_adapters, :env, :overrides]

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
            max_iterations: 10,
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
          max_iterations: pos_integer(),
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
  supply an `:env` map; normal callers use the process environment.
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
         {:ok, env_opts} <- environment_options(env) do
      file_opts
      |> Keyword.merge(env_opts)
      |> Keyword.merge(overrides)
      |> Keyword.put(:adapters, adapters)
      |> new()
    end
  end

  def load(opts), do: {:error, {:invalid_config_loader_options, opts}}

  @doc """
  Resolves and validates explicit session configuration.

  `:adapters` and a canonical `:model` reference such as
  `"openai-codex/gpt-5.5"` are required.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    with :ok <- validate_keyword(opts),
         :ok <- validate_known_options(opts),
         {:ok, adapters} <- fetch_adapters(opts),
         {:ok, model_ref} <- fetch_model_ref(opts),
         {:ok, llm} <- LLM.select(adapters, model_ref),
         {:ok, tools} <- validate_tools(Keyword.get(opts, :tools, [])),
         {:ok, hooks} <- validate_modules(:hooks, Keyword.get(opts, :hooks, [])),
         :ok <- validate_optional_string(:system_prompt, Keyword.get(opts, :system_prompt)),
         :ok <- validate_map(:context, Keyword.get(opts, :context, %{})),
         :ok <- validate_positive_integer(:max_iterations, Keyword.get(opts, :max_iterations, 10)),
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
         system_prompt: Keyword.get(opts, :system_prompt),
         context: Keyword.get(opts, :context, %{}),
         max_iterations: Keyword.get(opts, :max_iterations, 10),
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

  defp environment_options(env) do
    case Map.get(env, "TACKLE_MODEL") do
      nil -> {:ok, []}
      "" -> {:ok, []}
      model when is_binary(model) -> {:ok, [model: model]}
      _model -> {:error, {:invalid_environment, "TACKLE_MODEL"}}
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

  defp validate_positive_integer(_name, value) when is_integer(value) and value > 0, do: :ok
  defp validate_positive_integer(name, value), do: {:error, {:invalid_option, name, value}}

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
