defmodule Tackle.Skills.Skill do
  @moduledoc """
  One Agent Skill offered to the model.

  A skill comes from one of two sources:

    * `:file` — discovered under an `.agents/skills` directory. `path` is the
      absolute path of the skill's `SKILL.md`, and `dir` is the directory that
      contains it. The harness reads `path` when the skill is loaded, and the
      model resolves relative paths inside the skill against `dir`.
    * `:builtin` — supplied by the host with `Tackle.Skills.builtin/2`. It has
      no `path` or `dir`; `content` holds its instructions. Built-in skills are
      self-contained and cannot reference other files.

  Either kind is loaded by the model with the `load_skill` tool
  (`Tackle.Tools.LoadSkill`).

  `requires_tools` names tools an agent must have for the skill to be offered
  to it; see `Tackle.Skills.available/2`.
  """

  @enforce_keys [:name, :description]
  defstruct [
    :name,
    :description,
    :path,
    :dir,
    :content,
    source: :file,
    requires_tools: [],
    disable_model_invocation: false
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          path: Path.t() | nil,
          dir: Path.t() | nil,
          content: String.t() | nil,
          source: :file | :builtin,
          requires_tools: [String.t()],
          disable_model_invocation: boolean()
        }
end
