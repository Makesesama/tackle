defmodule Tackle.Agents.Definition do
  @moduledoc """
  Inert configuration discovered from a subagent Markdown file.

  Definitions contain names and scalar policy only. Executable modules are
  resolved later from capabilities already supplied by the trusted harness.
  """

  @enforce_keys [:name, :description, :prompt, :source]
  defstruct [
    :name,
    :description,
    :prompt,
    :source,
    :path,
    :model,
    :thinking,
    tools: nil,
    timeout: :timer.minutes(5),
    max_iterations: 20,
    advertise: false,
    allow_delegation: false
  ]

  @type source :: :builtin | :user | :project

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          prompt: String.t(),
          source: source(),
          path: Path.t() | nil,
          model: String.t() | nil,
          thinking: String.t() | nil,
          tools: [String.t()] | nil,
          timeout: pos_integer(),
          max_iterations: pos_integer(),
          advertise: boolean(),
          allow_delegation: boolean()
        }
end
