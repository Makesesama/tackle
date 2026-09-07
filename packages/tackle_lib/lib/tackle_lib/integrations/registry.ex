defmodule Tackle.Lib.Integrations.Registry do
  @moduledoc """
  Small registry for exposing `Tackle.Lib.Tool` modules through external integrations.

  The core `Tackle.Lib.Tool.Registry` is optimized for agent-loop execution and stale
  definition checks. This registry is intentionally simpler: integrations need a
  stable lookup table, tool definitions, and a registration order while the host
  application remains responsible for auth, routing, and context construction.
  """

  alias Tackle.Lib.Tool

  @type entry :: %{
          required(:name) => String.t(),
          required(:module) => module(),
          required(:definition) => map()
        }

  @type t :: %__MODULE__{entries: %{String.t() => entry()}, order: [String.t()]}

  defstruct entries: %{}, order: []

  @doc "Builds an integration registry from a list of `Tackle.Lib.Tool` modules."
  @spec new([module()]) :: t()
  def new(tools) when is_list(tools) do
    {entries, order} =
      Enum.reduce(tools, {%{}, []}, fn tool, {entries, order} ->
        definition = Tool.definition(tool)
        name = definition.name
        entry = %{name: name, module: tool, definition: definition}

        {Map.put(entries, name, entry), [name | order]}
      end)

    %__MODULE__{entries: entries, order: Enum.reverse(order)}
  end

  @doc "Returns the registered tool entries in declaration order."
  @spec entries(t()) :: [entry()]
  def entries(%__MODULE__{entries: entries, order: order}) do
    Enum.map(order, &Map.fetch!(entries, &1))
  end

  @doc "Looks up a tool entry by public tool name."
  @spec lookup(t(), String.t()) :: entry() | nil
  def lookup(%__MODULE__{entries: entries}, name) when is_binary(name), do: Map.get(entries, name)
end
