defmodule Tackle.Tools.LoadSkill do
  @moduledoc """
  Loads the instructions of an offered skill by name.

  This is the single way the model loads a skill, whether it is a `SKILL.md`
  file or a built-in skill (`Tackle.Skills.builtin/2`). `Tackle.Config.load/1`
  grants the tool, and places the skills offered to that agent in the session
  context under `:skills`, whenever at least one skill is offered.

  The tool only serves skills from that list, by name; the model cannot name a
  path. Files are read by the harness through `Tackle.Skills.load/2` with the
  session's executor, so user skills load even when a jailed executor cannot
  see `~/.agents/skills`.
  """

  use Tackle.Lib.Tool

  alias Tackle.{Executor, ProjectFiles, Skills}
  alias Tackle.Skills.Skill

  tool_name("load_skill")

  description(
    "Load the full instructions of a skill listed in <available_skills> by its name. " <>
      "Relative paths in a skill's instructions resolve against the skill directory " <>
      "returned with them."
  )

  input do
    field(:name, :string, required: true, description: "Name of the skill to load")
  end

  @impl true
  def effect, do: :read_only

  @spec run(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def run(%{"name" => name}, context) when is_binary(name) do
    skills = offered_skills(context)

    case Enum.find(skills, &(&1.name == name)) do
      %Skill{} = skill -> load(skill, context)
      nil -> {:error, unknown_skill(name, skills)}
    end
  end

  def run(_args, _context), do: {:error, "load_skill requires a skill name"}

  defp load(skill, context) do
    case Skills.load(skill, executor: Executor.from_context(context)) do
      {:ok, body} -> {:ok, render(skill, body)}
      {:error, reason} -> {:error, "could not load skill #{skill.name}: #{describe(reason)}"}
    end
  end

  defp render(%Skill{source: :file, dir: dir}, body),
    do: "Skill directory: #{dir}\n\n#{body}"

  defp render(%Skill{}, body), do: body

  defp offered_skills(context) do
    case Map.get(context, :skills) do
      skills when is_list(skills) -> Enum.filter(skills, &match?(%Skill{}, &1))
      _other -> []
    end
  end

  defp unknown_skill(name, []), do: "unknown skill #{inspect(name)}; none are available"

  defp unknown_skill(name, skills) do
    "unknown skill #{inspect(name)}; available: " <> Enum.map_join(skills, ", ", & &1.name)
  end

  defp describe(:unterminated_frontmatter), do: "the frontmatter is not terminated"
  defp describe(:malformed_frontmatter), do: "the frontmatter is malformed"
  defp describe(reason), do: ProjectFiles.format_error(reason)
end
