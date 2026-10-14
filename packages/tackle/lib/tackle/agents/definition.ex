defmodule Tackle.Agents.Definition do
  @moduledoc """
  Inert configuration discovered from a subagent Markdown file.

  Definitions contain names and scalar policy only. Executable modules are
  resolved later from capabilities already supplied by the trusted harness.

  `instructions` (default `true`) gives the profile the harness instruction
  files (`APPEND_SYSTEM.md`, `AGENTS.md`) and skills; with `false` its system
  prompt is only its own prompt and the working directory, and it gets no
  `load_skill` tool.
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
    max_iterations: :infinity,
    advertise: false,
    allow_delegation: false,
    instructions: true
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
          max_iterations: pos_integer() | :infinity,
          advertise: boolean(),
          allow_delegation: boolean(),
          instructions: boolean()
        }
end
