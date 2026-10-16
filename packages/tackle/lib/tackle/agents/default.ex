defmodule Tackle.Agents.Default do
  @moduledoc """
  Behaviour and registry for subagents shipped with the coding harness.

  Default agents provide inert definitions through `definition/0`. User and
  project Markdown definitions may still override them by name during discovery.
  """

  alias Tackle.Agents.Definition
  alias Tackle.Review.Stages

  @agents [
    Tackle.Agents.Default.Scout,
    Tackle.Agents.Default.Reviewer,
    Tackle.Agents.Default.Worker
  ]

  @callback definition() :: Definition.t()

  @doc """
  Returns the definitions shipped with the coding harness: the general
  agents, then the code review stages (`Tackle.Review.Stages`).

  The review stages are not advertised to the root agent, cannot delegate,
  and get no instruction files or skills; `Tackle.Review` starts their runs.
  Projects override them by name, for example with
  `.tackle/agents/review-detector.md`; an override must keep the stage's
  output tool.
  """
  @spec definitions() :: [Definition.t()]
  def definitions do
    Enum.map(@agents, & &1.definition()) ++ Enum.map(Stages.all(), &review_stage/1)
  end

  defp review_stage(stage) do
    %Definition{
      name: stage.name,
      description: stage.description,
      prompt: stage.prompt,
      source: :builtin,
      tools: stage.tools,
      max_iterations: stage.max_steps,
      advertise: false,
      allow_delegation: false,
      instructions: false
    }
  end
end
