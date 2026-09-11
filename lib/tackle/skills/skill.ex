defmodule Tackle.Skills.Skill do
  @moduledoc """
  One Agent Skill discovered under an `.agents/skills` directory.

  `path` is the absolute path of the skill's `SKILL.md`, and `dir` is the
  directory that contains it. The model resolves relative paths inside the
  skill against `dir`.
  """

  @enforce_keys [:name, :description, :path, :dir]
  defstruct [:name, :description, :path, :dir, disable_model_invocation: false]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          path: Path.t(),
          dir: Path.t(),
          disable_model_invocation: boolean()
        }
end
