defmodule Tackle.Config.Prompt do
  @moduledoc false

  # Assembles a configuration's system prompt and skills from its sources,
  # without reading anything: the skills the configuration's tools can use are
  # offered with `Tackle.Tools.LoadSkill`, and the prompt is composed from the
  # prompt files `Tackle.Config.Sources` read.

  alias Tackle.Config.Sources
  alias Tackle.Skills
  alias Tackle.SystemPrompt
  alias Tackle.Tools.LoadSkill

  @doc """
  Puts the working directory, the Tackle and user homes, the offered skills,
  the `load_skill` tool, and the system prompt into `config`. `base` replaces
  the base prompt; `instructions: false` leaves out the instruction files and
  skills.
  """
  @spec assemble(Tackle.Config.t(), Sources.t(), String.t() | nil, boolean()) ::
          {:ok, Tackle.Config.t()} | {:error, term()}
  def assemble(config, %Sources{} = sources, base, instructions) do
    context =
      Map.merge(config.context, %{
        cwd: sources.cwd,
        tackle_home: sources.home,
        user_home: sources.user_home
      })

    skills = if instructions, do: Skills.available(sources.skills, config.tools), else: []

    with {:ok, tools, context} <- grant_skills(config.tools, context, skills),
         {:ok, prompt} <-
           SystemPrompt.compose(sources.prompt_files,
             base: base,
             cwd: sources.cwd,
             tools: tools,
             skills: skills,
             instructions: instructions
           ) do
      {:ok, %{config | tools: tools, context: context, system_prompt: prompt}}
    end
  end

  # Offering a skill also grants the tool that loads it, for file and built-in
  # skills alike.
  defp grant_skills(tools, context, skills) do
    case Enum.reject(skills, & &1.disable_model_invocation) do
      [] ->
        {:ok, tools, context}

      offered ->
        with :ok <- ensure_load_skill_name_free(tools) do
          {:ok, append_load_skill(tools), Map.put(context, :skills, offered)}
        end
    end
  end

  defp append_load_skill(tools) do
    if LoadSkill in tools, do: tools, else: Enum.reverse([LoadSkill | Enum.reverse(tools)])
  end

  # The tool is granted after the configuration's tools were checked, so a
  # different tool with the same name must be reported here rather than when
  # the session starts.
  defp ensure_load_skill_name_free(tools) do
    name = LoadSkill.name()

    if Enum.any?(tools, &(&1 != LoadSkill and &1.name() == name)),
      do: {:error, {:tool_name_conflict, name}},
      else: :ok
  end
end
