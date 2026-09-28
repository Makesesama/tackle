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

  @type entry :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          required(:module) => module(),
          required(:definition) => map()
        }

  @type t :: %__MODULE__{entries: %{String.t() => entry()}}

  defstruct entries: %{}

  @doc """
  Builds a registry from a list of `Tackle.Lib.Tool` modules.

  Raises `ArgumentError` for a module missing required tool callbacks, an invalid
  tool name, or a duplicate name (including a module listed twice).
  """
  @spec new([module()]) :: t()
  def new(tools) when is_list(tools) do
    entries =
      Enum.reduce(tools, %{}, fn tool_module, entries ->
        validate_tool_module!(tool_module)
        definition = Tool.definition(tool_module)
        name = definition.name

        unless is_binary(name) and name != "" do
          raise ArgumentError, "invalid tool name for #{inspect(tool_module)}: #{inspect(name)}"
        end

        if Map.has_key?(entries, name) do
          raise ArgumentError, "duplicate tool name: #{inspect(name)}"
        end

        Map.put(entries, name, %{
          id: definition.definition_id,
          name: name,
          module: tool_module,
          definition: definition
        })
      end)

    %__MODULE__{entries: entries}
  end

  @doc "Returns provider-neutral definitions with stable definition ids."
  @spec definitions(t()) :: [map()]
  def definitions(%__MODULE__{entries: entries}) do
    entries
    |> Map.values()
    |> Enum.map(& &1.definition)
  end

  @doc "Resolves a tool call to a registered tool module or returns a structured rejection."
  @spec resolve(t(), Call.t()) ::
          {:ok, entry()} | {:error, :unknown_tool | :stale_tool_definition}
  def resolve(%__MODULE__{entries: entries}, %Call{name: name, definition_id: definition_id}) do
    case Map.get(entries, name) do
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

  @doc "Fetches an entry by tool name."
  @spec get(t(), String.t()) :: entry() | nil
  def get(%__MODULE__{entries: entries}, name), do: Map.get(entries, name)

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
