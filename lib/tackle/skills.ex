defmodule Tackle.Skills do
  @moduledoc """
  Discovers Agent Skills from `.agents/skills` directories.

  A skill is a directory containing a `SKILL.md` file whose YAML frontmatter
  declares a `name` and a `description`. Tackle follows the
  [Agent Skills standard](https://agentskills.io/specification) locations:

    * the project `.agents/skills` directory in the working directory and its
      ancestors up to the git repository root; and
    * the user-level `~/.agents/skills` directory.

  Only the name, description, and `SKILL.md` location are included in the
  system prompt; the model reads the full file on demand with its file tool.
  This is progressive disclosure: descriptions are always in context, skill
  bodies are loaded only when the task matches.

  Discovery is lenient. A missing `description`, unreadable file, or malformed
  frontmatter produces a warning and the skill is skipped; an invalid name or an
  over-long description produces a warning but the skill still loads. A name
  collision keeps the first skill found and warns about the rest. Nearest
  project skills win over more distant project skills and user skills.
  """

  alias Tackle.Paths
  alias Tackle.Skills.{Frontmatter, Skill}

  @skill_file "SKILL.md"
  @agents_dir ".agents"
  @skills_dir "skills"
  @ignored_entries ["node_modules"]
  @max_name_length 64
  @max_description_length 1024
  @name_pattern ~r/^[a-z0-9]+(-[a-z0-9]+)*$/

  @typedoc "A non-fatal skill discovery problem."
  @type warning :: %{path: Path.t(), message: String.t()}

  @typedoc "Discovered skills in precedence order plus any warnings."
  @type discovery :: %{skills: [Skill.t()], warnings: [warning()]}

  @typedoc "`discover/1` options. `:cwd` selects the project directory."
  @type discover_option :: {:cwd, Path.t()} | {:user_home, String.t() | nil}

  @doc """
  Discovers skills from the project and user `.agents/skills` directories.

  Project directories are searched from the working directory outward, and the
  user directory is searched last. The returned skills preserve that precedence
  order.

  Options:

    * `:cwd` - working directory for project discovery, defaults to the current
      working directory;
    * `:user_home` - override for `~`; `nil` disables user skill discovery.
  """
  @spec discover([discover_option()]) :: discovery()
  def discover(opts \\ []) do
    cwd = opts |> Keyword.get(:cwd) |> resolve_cwd()

    {skills, warnings} =
      (project_dirs(cwd) ++ global_dirs(opts))
      |> Enum.flat_map(&skill_files/1)
      |> Enum.reduce({[], []}, &load_file/2)

    skills
    |> :lists.reverse()
    |> dedupe(warnings)
  end

  defp resolve_cwd(nil), do: File.cwd!() |> Path.expand()
  defp resolve_cwd(cwd) when is_binary(cwd), do: Path.expand(cwd)

  @doc """
  Renders visible skills as an `<available_skills>` block for a system prompt.

  Skills with `disable_model_invocation: true` are omitted because they are not
  offered to the model. Returns an empty string when no skill is visible.

  The `:tools` option is the tool module list being offered to the model; it
  selects the file-loading instruction for the prompt.
  """
  @spec format_for_prompt([Skill.t()], keyword()) :: String.t()
  def format_for_prompt(skills, opts \\ []) when is_list(skills) do
    visible = Enum.reject(skills, & &1.disable_model_invocation)

    case visible do
      [] -> ""
      visible -> render(visible, loader_hint(Keyword.get(opts, :tools, [])))
    end
  end

  defp load_file(path, {skills, warnings}) do
    case load_skill(path) do
      {:ok, skill, file_warnings} -> {[skill | skills], warnings ++ file_warnings}
      {:error, file_warnings} -> {skills, warnings ++ file_warnings}
    end
  end

  defp load_skill(path) do
    with {:ok, contents} <- read(path),
         {:ok, frontmatter} <- Frontmatter.parse(contents) do
      build(path, frontmatter)
    else
      {:error, %{} = warning} -> {:error, [warning]}
      {:error, reason} -> {:error, [warning(path, "malformed frontmatter (#{inspect(reason)})")]}
    end
  end

  defp build(path, frontmatter) do
    dir = Path.dirname(path)
    name = frontmatter |> Map.get("name") |> normalize_name(Path.basename(dir))
    description = frontmatter |> Map.get("description") |> normalize_description()

    case description do
      "" ->
        {:error, [warning(path, "description is required")]}

      description ->
        warnings =
          name_warnings(path, name) ++ description_warnings(path, description)

        skill = %Skill{
          name: name,
          description: description,
          path: path,
          dir: dir,
          disable_model_invocation: Map.get(frontmatter, "disable-model-invocation") == true
        }

        {:ok, skill, warnings}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, contents} ->
        if String.valid?(contents) do
          {:ok, contents}
        else
          {:error, warning(path, "file is not valid UTF-8")}
        end

      {:error, reason} ->
        {:error, warning(path, "could not be read (#{:file.format_error(reason)})")}
    end
  end

  defp normalize_name(name, fallback) when is_binary(name) do
    case String.trim(name) do
      "" -> fallback
      trimmed -> trimmed
    end
  end

  defp normalize_name(_name, fallback), do: fallback

  defp normalize_description(description) when is_binary(description) do
    description
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.join(" ")
  end

  defp normalize_description(_description), do: ""

  defp name_warnings(path, name) do
    cond do
      not is_binary(name) or String.trim(name) == "" ->
        [warning(path, "name is required")]

      String.length(name) > @max_name_length ->
        [warning(path, "name exceeds #{@max_name_length} characters")]

      not Regex.match?(@name_pattern, name) ->
        [warning(path, "name must use lowercase letters, numbers, and single hyphens")]

      true ->
        []
    end
  end

  defp description_warnings(path, description) do
    if String.length(description) > @max_description_length do
      [warning(path, "description exceeds #{@max_description_length} characters")]
    else
      []
    end
  end

  defp dedupe(skills, warnings) do
    {skills, warnings} =
      Enum.reduce(skills, {[], warnings}, fn skill, {accepted, warnings} ->
        cond do
          Enum.any?(accepted, &(&1.path == skill.path)) ->
            {accepted, warnings}

          collision = Enum.find(accepted, &(&1.name == skill.name)) ->
            {accepted, warnings ++ [collision_warning(skill, collision)]}

          true ->
            {accepted ++ [skill], warnings}
        end
      end)

    %{skills: skills, warnings: warnings}
  end

  defp collision_warning(skill, winner) do
    %{
      path: skill.path,
      message: "skill name #{skill.name} is already loaded from #{winner.path}"
    }
  end

  defp warning(path, message), do: %{path: path, message: message}

  defp project_dirs(cwd) do
    cwd
    |> ancestors()
    |> Enum.map(&Path.join([&1, @agents_dir, @skills_dir]))
  end

  defp global_dirs(opts) do
    case Paths.agents_dir(user_home: Keyword.get(opts, :user_home)) do
      {:ok, agents_dir} -> [Path.join(agents_dir, @skills_dir)]
      {:error, _reason} -> []
    end
  end

  defp ancestors(dir) do
    collect_ancestors(dir, git_root(dir), [])
  end

  defp collect_ancestors(dir, git_root, acc) do
    parent = Path.dirname(dir)
    acc = [dir | acc]

    cond do
      dir == parent -> :lists.reverse(acc)
      git_root != nil and dir == git_root -> :lists.reverse(acc)
      true -> collect_ancestors(parent, git_root, acc)
    end
  end

  defp git_root(dir) do
    parent = Path.dirname(dir)

    cond do
      File.exists?(Path.join(dir, ".git")) -> dir
      dir == parent -> nil
      true -> git_root(parent)
    end
  end

  defp skill_files(dir) do
    skill_file = Path.join(dir, @skill_file)

    cond do
      file?(skill_file) -> [skill_file]
      not File.dir?(dir) -> []
      true -> dir |> children() |> Enum.flat_map(&skill_files/1)
    end
  end

  defp children(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.reject(&ignored?/1)
        |> Enum.map(&Path.join(dir, &1))

      {:error, _reason} ->
        []
    end
  end

  defp ignored?(entry), do: String.starts_with?(entry, ".") or entry in @ignored_entries

  defp file?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} -> true
      _other -> false
    end
  end

  defp render(skills, hint) do
    lines =
      [
        "The following skills provide specialized instructions for specific tasks.",
        hint,
        "When a skill file references a relative path, resolve it against the skill directory " <>
          "(the directory containing SKILL.md) and use that absolute path in tool commands.",
        "",
        "<available_skills>"
      ] ++
        Enum.flat_map(skills, fn skill ->
          [
            "  <skill>",
            "    <name>#{escape(skill.name)}</name>",
            "    <description>#{escape(skill.description)}</description>",
            "    <location>#{escape(skill.path)}</location>",
            "  </skill>"
          ]
        end) ++ ["</available_skills>"]

    Enum.join(lines, "\n")
  end

  defp loader_hint(tools) do
    names = Enum.map(tools, &tool_name/1)

    cond do
      "read" in names ->
        "Use the read tool to load a skill's file when the task matches its description."

      "bash" in names ->
        "Use bash to load a skill's file when the task matches its description."

      true ->
        "Load a skill's file when the task matches its description."
    end
  end

  defp tool_name(tool) when is_atom(tool), do: tool.name()
  defp tool_name(tool) when is_binary(tool), do: tool

  defp escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
