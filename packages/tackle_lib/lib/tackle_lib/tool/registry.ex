defmodule Tackle.Lib.Tool.Registry do
  @moduledoc """
  Immutable registry of tools available to a Tackle.Lib run.

  The registry materializes tool modules into provider-neutral definitions and
  assigns each one a deterministic `definition_id`. If a tool call includes a
  `definition_id`, resolution rejects stale calls whose id no longer matches the
  registered definition for that name.
  """

  alias Tackle.Lib.Tool
  alias Tackle.Lib.Tool.Call
  alias Tackle.Lib.Tool.Schema

  @type entry :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          required(:module) => module(),
          required(:definition) => map()
        }

  @typedoc """
  A registry: its entries in registration order, and the same entries by
  tool name.
  """
  @type t :: %__MODULE__{entries: [entry()], by_name: %{String.t() => entry()}}

  defstruct entries: [], by_name: %{}

  @doc """
  Builds a registry from a list of `Tackle.Lib.Tool` modules.

  Raises `ArgumentError` for a module missing required tool callbacks, an invalid
  tool name, a duplicate name (including a module listed twice), or a
  parameters schema or keyword output schema that does not pass
  `Tackle.Lib.Tool.Schema.validate_schema/1`.
  """
  @spec new([module()]) :: t()
  def new(tools) when is_list(tools) do
    {entries, by_name} =
      Enum.reduce(tools, {[], %{}}, fn tool_module, {entries, by_name} ->
        entry = entry!(tool_module)

        if Map.has_key?(by_name, entry.name) do
          raise ArgumentError, "duplicate tool name: #{inspect(entry.name)}"
        end

        {[entry | entries], Map.put(by_name, entry.name, entry)}
      end)

    %__MODULE__{entries: Enum.reverse(entries), by_name: by_name}
  end

  defp entry!(tool_module) do
    validate_tool_module!(tool_module)
    validate_schemas!(tool_module)
    definition = Tool.definition(tool_module)
    name = definition.name

    unless is_binary(name) and name != "" do
      raise ArgumentError, "invalid tool name for #{inspect(tool_module)}: #{inspect(name)}"
    end

    %{id: definition.definition_id, name: name, module: tool_module, definition: definition}
  end

  @doc "Returns the registered entries, in the order their modules were given to `new/1`."
  @spec entries(t()) :: [entry()]
  def entries(%__MODULE__{entries: entries}), do: entries

  @doc "Returns the registered tool modules, in the order they were given to `new/1`."
  @spec modules(t()) :: [module()]
  def modules(%__MODULE__{entries: entries}), do: Enum.map(entries, & &1.module)

  @doc """
  Returns provider-neutral definitions with stable definition ids, in the
  order their modules were given to `new/1`.
  """
  @spec definitions(t()) :: [map()]
  def definitions(%__MODULE__{entries: entries}), do: Enum.map(entries, & &1.definition)

  @doc "Looks up an entry by tool name, or returns `nil`."
  @spec lookup(t(), String.t()) :: entry() | nil
  def lookup(%__MODULE__{by_name: by_name}, name) when is_binary(name),
    do: Map.get(by_name, name)

  @doc "Resolves a tool call to a registered tool module or returns a structured rejection."
  @spec resolve(t(), Call.t()) ::
          {:ok, entry()} | {:error, :unknown_tool | :stale_tool_definition}
  def resolve(%__MODULE__{by_name: by_name}, %Call{name: name, definition_id: definition_id}) do
    case Map.get(by_name, name) do
      nil ->
        {:error, :unknown_tool}

      %{id: ^definition_id} = entry when is_binary(definition_id) ->
        {:ok, entry}

      %{id: current_id} when is_binary(definition_id) and definition_id != current_id ->
        {:error, :stale_tool_definition}

      entry ->
        {:ok, entry}
    end
  end

  defp validate_schemas!(tool_module) do
    validate_schema!(tool_module, "parameters", tool_module.parameters_schema())

    case Tool.output_schema(tool_module) do
      schema when is_list(schema) -> validate_schema!(tool_module, "output", schema)
      _nil_or_external -> :ok
    end
  end

  defp validate_schema!(tool_module, kind, schema) do
    case Schema.validate_schema(schema) do
      :ok ->
        :ok

      {:error, message} ->
        raise ArgumentError, "#{inspect(tool_module)} has an invalid #{kind} schema: #{message}"
    end
  end

  defp validate_tool_module!(tool_module) do
    required = [name: 0, description: 0, parameters_schema: 0, execute: 2]

    missing =
      if is_atom(tool_module) and Code.ensure_loaded?(tool_module) do
        Enum.reject(required, fn {name, arity} ->
          function_exported?(tool_module, name, arity)
        end)
      else
        required
      end

    if missing != [] do
      callbacks = Enum.map_join(missing, ", ", fn {name, arity} -> "#{name}/#{arity}" end)

      raise ArgumentError,
            "#{inspect(tool_module)} is not a valid Tackle.Lib.Tool; missing callbacks: #{callbacks}"
    end
  end
end
