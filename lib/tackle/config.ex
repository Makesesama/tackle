defmodule Tackle.Config do
  @moduledoc """
  Validated, frontend-independent configuration for one Tackle session.

  The initial harness accepts already-loaded adapter, tool, hook, and prompt
  renderer modules. Reading configuration files and loading extension projects
  are separate concerns and are intentionally not part of this module yet.
  """

  alias Tackle.Lib.LLM
  alias Tackle.Lib.LLM.Selection
  alias Tackle.Lib.Tool.Adapters.Web, as: ToolAdapter
  alias Tackle.Lib.Tool.Policy
  alias Tackle.Lib.Tool.Registry, as: ToolRegistry

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
            id_generator: &Tackle.Lib.ID.uuid4/0,
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
          id_generator: Tackle.Lib.ID.generator(),
          llm_stream: boolean()
        }

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
         :ok <-
           validate_keyword_option(
             :prompt_renderer_opts,
             Keyword.get(opts, :prompt_renderer_opts, [])
           ),
         :ok <- validate_prompt_renderer(Keyword.get(opts, :prompt_renderer)),
         :ok <- validate_id_generator(Keyword.get(opts, :id_generator, &Tackle.Lib.ID.uuid4/0)),
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
         id_generator: Keyword.get(opts, :id_generator, &Tackle.Lib.ID.uuid4/0),
         llm_stream: Keyword.get(opts, :llm_stream, false)
       }}
    end
  end

  def new(opts), do: {:error, {:invalid_config, opts}}

  @doc "Builds the initial library state for a configured session."
  @spec to_agent_state(t()) :: Tackle.Lib.State.t()
  def to_agent_state(%__MODULE__{} = config) do
    Tackle.Lib.new(
      llm: config.llm,
      tools: config.tools,
      hooks: config.hooks,
      system_prompt: config.system_prompt,
      context: config.context,
      max_iterations: config.max_iterations,
      tool_policy: config.tool_policy,
      llm_opts: config.llm_opts,
      prompt_renderer: config.prompt_renderer,
      prompt_renderer_opts: config.prompt_renderer_opts,
      id_generator: config.id_generator
    )
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
