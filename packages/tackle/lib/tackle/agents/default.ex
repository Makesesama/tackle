defmodule Tackle.Agents.Default do
  @moduledoc """
  Behaviour and registry for subagents shipped with the coding harness.

  Default agents provide inert definitions through `definition/0`. User and
  project Markdown definitions may still override them by name during discovery.
  """

  alias Tackle.Agents.Definition

  @agents [
    Tackle.Agents.Default.Scout,
    Tackle.Agents.Default.Reviewer,
    Tackle.Agents.Default.Worker
  ]

  @callback definition() :: Definition.t()

  @doc "Returns the definitions shipped with the coding harness."
  @spec definitions() :: [Definition.t()]
  def definitions do
    Enum.map(@agents, & &1.definition())
  end
end
