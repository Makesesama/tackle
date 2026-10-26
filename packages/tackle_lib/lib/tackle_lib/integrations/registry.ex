defmodule Tackle.Lib.Integrations.Registry do
  @moduledoc """
  Registry for exposing `Tackle.Lib.Tool` modules through external integrations.

  It is the provider-neutral seam for bridges such as an MCP server: they need
  the tools' definitions in registration order and a lookup by public name,
  while the host application remains responsible for auth, routing, and
  context construction. It is built on `Tackle.Lib.Tool.Registry`, so tools are
  validated the same way as for the agent loop, and a duplicate tool name
  raises `ArgumentError`.
  """

  alias Tackle.Lib.Tool.Registry, as: ToolRegistry

  @type entry :: ToolRegistry.entry()

  @type t :: %__MODULE__{tools: ToolRegistry.t()}

  defstruct tools: %ToolRegistry{}

  @doc """
  Builds an integration registry from a list of `Tackle.Lib.Tool` modules.

  Raises `ArgumentError` like `Tackle.Lib.Tool.Registry.new/1`, including for a
  duplicate tool name.
  """
  @spec new([module()]) :: t()
  def new(tools) when is_list(tools), do: %__MODULE__{tools: ToolRegistry.new(tools)}

  @doc "Returns the registered tool entries in declaration order."
  @spec entries(t()) :: [entry()]
  def entries(%__MODULE__{tools: tools}), do: ToolRegistry.entries(tools)

  @doc "Looks up a tool entry by public tool name."
  @spec lookup(t(), String.t()) :: entry() | nil
  def lookup(%__MODULE__{tools: tools}, name) when is_binary(name),
    do: ToolRegistry.lookup(tools, name)
end
