defmodule Tackle.Plugins.Catalog do
  @moduledoc """
  Validated, provenance-preserving catalog of harness plugin contributions.

  Catalog inputs are trusted modules explicitly supplied by the host. Tool
  lookup only selects from this catalog; it never grants additional tools.
  """

  alias Tackle.Lib.Hook

  @enforce_keys [:adapters, :tools, :hooks]
  defstruct adapters: [], tools: [], hooks: []

  @type entry :: %{required(:module) => module(), required(:source) => term()}
  @type t :: %__MODULE__{adapters: [entry()], tools: [entry()], hooks: [entry()]}

  @adapter_id_pattern ~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/

  @doc "Builds a catalog, validating each entry while retaining its source."
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    with :ok <- valid_options(opts),
         {:ok, adapters} <- validate_kind(Keyword.fetch!(opts, :adapters), :adapter),
         {:ok, tools} <- validate_kind(Keyword.fetch!(opts, :tools), :tool),
         {:ok, hooks} <- validate_kind(Keyword.fetch!(opts, :hooks), :hook) do
      {:ok, %__MODULE__{adapters: adapters, tools: tools, hooks: hooks}}
    end
  end

  def new(opts), do: {:error, {:invalid_catalog_options, opts}}

  @doc "Returns ordered validated adapter entries."
  @spec adapters(t()) :: [entry()]
  def adapters(%__MODULE__{adapters: entries}), do: entries

  @doc "Returns ordered validated tool entries."
  @spec tools(t()) :: [entry()]
  def tools(%__MODULE__{tools: entries}), do: entries

  @doc "Returns ordered validated hook entries."
  @spec hooks(t()) :: [entry()]
  def hooks(%__MODULE__{hooks: entries}), do: entries

  @doc "Returns the selected adapter modules in declaration order."
  @spec adapter_modules(t()) :: [module()]
  def adapter_modules(%__MODULE__{} = catalog), do: Enum.map(adapters(catalog), & &1.module)

  @doc "Returns the selected hook modules in declaration order."
  @spec hook_modules(t()) :: [module()]
  def hook_modules(%__MODULE__{} = catalog), do: Enum.map(hooks(catalog), & &1.module)

  @doc "Resolves names only against tools explicitly present in this catalog."
  @spec resolve_tools(t(), [String.t()]) :: {:ok, [entry()]} | {:error, term()}
  def resolve_tools(%__MODULE__{tools: entries}, names) when is_list(names) do
    if Enum.all?(names, &is_binary/1) do
      resolve_tool_names(entries, names)
    else
      {:error, {:invalid_tool_names, names}}
    end
  end

  def resolve_tools(%__MODULE__{}, names), do: {:error, {:invalid_tool_names, names}}

  defp resolve_tool_names(entries, names) do
    by_name = Map.new(entries, fn entry -> {entry.module.name(), entry} end)

    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, resolved} ->
      case Map.fetch(by_name, name) do
        {:ok, entry} -> {:cont, {:ok, [entry | resolved]}}
        :error -> {:halt, {:error, {:unknown_tool, name}}}
      end
    end)
    |> case do
      {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
      error -> error
    end
  end

  defp valid_options(opts) do
    required = [:adapters, :tools, :hooks]

    cond do
      not Keyword.keyword?(opts) ->
        {:error, {:invalid_catalog_options, opts}}

      Enum.any?(required, &(not Keyword.has_key?(opts, &1))) ->
        {:error,
         {:missing_catalog_option, Enum.find(required, &(not Keyword.has_key?(opts, &1)))}}

      Enum.any?(Keyword.keys(opts), &(&1 not in required)) ->
        {:error, {:unknown_catalog_options, Keyword.keys(opts) -- required}}

      true ->
        :ok
    end
  end

  defp validate_kind(entries, kind) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, [], MapSet.new()}, fn entry, {:ok, acc, seen} ->
      case validate_kind_entry(entry, kind, seen) do
        {:ok, value, next_seen} -> {:cont, {:ok, [value | acc], next_seen}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed, _seen} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp validate_kind(entries, kind), do: {:error, {:invalid_catalog_entries, kind, entries}}

  defp validate_kind_entry(entry, kind, seen) do
    case validate_entry(entry, kind) do
      {:ok, value, key} ->
        if MapSet.member?(seen, key) do
          entry_error(entry, kind, {:duplicate, key})
        else
          {:ok, value, MapSet.put(seen, key)}
        end

      error ->
        error
    end
  end

  defp validate_entry(%{module: module, source: source} = entry, kind)
       when map_size(entry) == 2 and is_atom(module) do
    with :ok <- ensure_module(module, source, kind),
         {:ok, key} <- validate_module(module, source, kind) do
      {:ok, %{module: module, source: source}, key}
    end
  end

  defp validate_entry(entry, kind), do: entry_error(entry, kind, :invalid_entry_shape)

  defp validate_adapter(module, source) do
    with :ok <- required_callback(module, :generate, 2, source, :adapter),
         {:ok, id} <- callback(module, :adapter_id, 0, source, :adapter),
         true <- is_binary(id) and Regex.match?(@adapter_id_pattern, id),
         :ok <- validate_adapter_models(module, source) do
      {:ok, id}
    else
      false ->
        entry_error(
          %{module: module, source: source},
          :adapter,
          {:invalid_adapter_id, safe_call(module, :adapter_id)}
        )

      error ->
        error
    end
  end

  defp validate_adapter_models(module, source) do
    case callback(module, :models, 0, source, :adapter) do
      {:ok, models} ->
        if valid_models?(models) do
          :ok
        else
          entry_error(%{module: module, source: source}, :adapter, {:invalid_models, models})
        end

      error ->
        error
    end
  end

  defp valid_models?(models) when is_list(models) and models != [] do
    Enum.all?(models, &(is_binary(&1) and &1 != "" and &1 == String.trim(&1))) and
      length(Enum.uniq(models)) == length(models)
  end

  defp valid_models?(_models), do: false

  defp validate_module(module, source, :adapter), do: validate_adapter(module, source)

  defp validate_module(module, source, :tool) do
    with :ok <- tool_callbacks(module, source),
         {:ok, name} <- callback(module, :name, 0, source, :tool),
         true <- is_binary(name) and name != "" do
      {:ok, name}
    else
      false ->
        entry_error(
          %{module: module, source: source},
          :tool,
          {:invalid_tool_name, safe_call(module, :name)}
        )

      error ->
        error
    end
  end

  defp validate_module(module, source, :hook) do
    callbacks = Hook.behaviour_info(:callbacks) ++ Hook.behaviour_info(:optional_callbacks)

    if Enum.any?(callbacks, fn {name, arity} -> function_exported?(module, name, arity) end),
      do: {:ok, module},
      else: entry_error(%{module: module, source: source}, :hook, :no_hook_callbacks)
  end

  defp tool_callbacks(module, source) do
    Enum.reduce_while([{:description, 0}, {:parameters_schema, 0}, {:execute, 2}], :ok, fn
      {function, arity}, :ok ->
        case required_callback(module, function, arity, source, :tool) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
    end)
  end

  defp required_callback(module, function, arity, source, kind) do
    if function_exported?(module, function, arity),
      do: :ok,
      else:
        entry_error(
          %{module: module, source: source},
          kind,
          {:missing_callback, {function, arity}}
        )
  end

  defp callback(module, function, arity, source, kind) do
    if function_exported?(module, function, arity) do
      try do
        {:ok, apply(module, function, [])}
      rescue
        error ->
          entry_error(
            %{module: module, source: source},
            kind,
            {:callback_failed, function, Exception.message(error)}
          )
      catch
        type, reason ->
          entry_error(
            %{module: module, source: source},
            kind,
            {:callback_failed, function, {type, reason}}
          )
      end
    else
      entry_error(%{module: module, source: source}, kind, {:missing_callback, {function, arity}})
    end
  end

  defp ensure_module(module, source, kind) do
    if Code.ensure_loaded?(module),
      do: :ok,
      else: entry_error(%{module: module, source: source}, kind, :module_not_loaded)
  end

  defp entry_error(%{source: source}, kind, reason),
    do: {:error, {:invalid_plugin, kind, source, reason}}

  defp entry_error(entry, kind, reason), do: {:error, {:invalid_plugin, kind, entry, reason}}

  defp safe_call(module, function) do
    apply(module, function, [])
  rescue
    _ -> nil
  end
end
