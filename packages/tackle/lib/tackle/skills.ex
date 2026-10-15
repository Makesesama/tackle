defmodule Tackle.Skills do
  @moduledoc """
  Discovers Agent Skills from `.agents/skills` directories.

  A skill is a directory containing a `SKILL.md` file whose YAML frontmatter
  declares a `name` and a `description`. Tackle follows the
  [Agent Skills standard](https://agentskills.io/specification) locations:

    * the project `.agents/skills` directory in the working directory and its
      ancestors up to the git repository root; and
    * the user-level `~/.agents/skills` directory.

  Only the name, description, and skill directory are included in the system
  prompt; the model loads a skill's instructions on demand with the
  `load_skill` tool (`Tackle.Tools.LoadSkill`), which calls `load/2`. This is
  progressive disclosure: descriptions are always in context, skill bodies are
  loaded only when the task matches.

  The harness reads skill files itself through `Tackle.ProjectFiles`, so a
  skill under `~/.agents/skills` loads even when a jailed executor cannot see
  that directory. Files a skill references relative to its directory are still
  accessed with the agent's own tools.

  A host can also ship built-in skills with its distribution, such as a guide
  for a tool it bundles. `builtin/2` builds one from `SKILL.md` text, and
  `discover/1` accepts them through its `:builtins` option. Built-in skills
  carry their instructions in memory (an escript has no `priv` directory to
  read them from) and must be self-contained. File skills with the same name
  override built-in ones without a warning, so users can replace a bundled
  guide.

  Discovery is lenient. A missing `description`, unreadable file, or malformed
  frontmatter produces a warning and the skill is skipped; an invalid name or an
  over-long description produces a warning but the skill still loads. A name
  collision keeps the first skill found and warns about the rest. Nearest
  project skills win over more distant project skills and user skills.
  """

  alias Tackle.{Executor, Paths, ProjectFiles}
  alias Tackle.Skills.{Frontmatter, Skill}
  alias Tackle.Tools.LoadSkill

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
  @type discover_option ::
          {:cwd, Path.t()}
          | {:user_home, String.t() | nil}
          | {:executor, Tackle.Executor.t()}
          | {:builtins, [Skill.t()]}

  @typedoc "`builtin/2` options."
  @type builtin_option :: {:requires_tools, [String.t()]}

  @doc """
  Discovers skills from the project and user `.agents/skills` directories.

  Project directories are searched from the working directory outward, and the
  user directory is searched last. The returned skills preserve that precedence
  order.

  Options:

    * `:cwd` - working directory for project discovery, defaults to the current
      working directory;
    * `:user_home` - override for `~`; `nil` disables user skill discovery;
    * `:executor` - executor for files inside the working directory (see
      `Tackle.ProjectFiles`), defaults to the local executor;
    * `:builtins` - built-in skills from `builtin/2`, which rank below every
      discovered file skill.
  """
  @spec discover([discover_option()]) :: discovery()
  def discover(opts \\ []) do
    cwd = opts |> Keyword.get(:cwd) |> resolve_cwd()
    files = ProjectFiles.new(executor: Keyword.get(opts, :executor))

    {skills, warnings} =
      (project_dirs(files, cwd) ++ global_dirs(opts))
      |> Enum.flat_map(&skill_files(files, &1))
      |> Enum.reduce({[], []}, &load_file(files, &1, &2))

    skills
    |> :lists.reverse()
    |> Kernel.++(Keyword.get(opts, :builtins, []))
    |> dedupe(warnings)
  end

  @doc """
  Builds a built-in skill from `SKILL.md` text supplied by a trusted host.

  The frontmatter must declare a valid `name` and a `description`, and the
  body must not be empty. Unlike file discovery, which is lenient, problems
  are explicit errors: a built-in skill is part of the host's distribution.

  Options:

    * `:requires_tools` - tool names an agent must have for the skill to be
      offered to it (see `available/2`), defaults to `[]`.
  """
  @spec builtin(String.t(), [builtin_option()]) :: {:ok, Skill.t()} | {:error, term()}
  def builtin(markdown, opts \\ [])

  def builtin(markdown, opts) when is_binary(markdown) and is_list(opts) do
    with {:ok, requires_tools} <- requires_tools(opts),
         {:ok, document} <- builtin_document(markdown),
         {:ok, name} <- builtin_name(document.frontmatter),
         {:ok, description} <- builtin_description(document.frontmatter),
         :ok <- builtin_body(document.body) do
      {:ok,
       %Skill{
         name: name,
         description: description,
         content: document.body,
         source: :builtin,
         requires_tools: requires_tools,
         disable_model_invocation:
           Map.get(document.frontmatter, "disable-model-invocation") == true
       }}
    end
  end

  def builtin(markdown, opts), do: {:error, {:invalid_builtin_skill, {markdown, opts}}}

  defp requires_tools(opts) do
    case Keyword.get(opts, :requires_tools, []) do
      names when is_list(names) ->
        if Enum.all?(names, &(is_binary(&1) and &1 != "")),
          do: {:ok, Enum.uniq(names)},
          else: {:error, {:invalid_builtin_skill, {:requires_tools, names}}}

      other ->
        {:error, {:invalid_builtin_skill, {:requires_tools, other}}}
    end
  end

  defp builtin_document(markdown) do
    case Frontmatter.parse_document(markdown) do
      {:ok, document} -> {:ok, document}
      {:error, reason} -> {:error, {:invalid_builtin_skill, reason}}
    end
  end

  defp builtin_name(frontmatter) do
    name = Map.get(frontmatter, "name")

    if is_binary(name) and String.length(name) <= @max_name_length and
         Regex.match?(@name_pattern, name),
       do: {:ok, name},
       else: {:error, {:invalid_builtin_skill, {:name, name}}}
  end

  defp builtin_description(frontmatter) do
    case frontmatter |> Map.get("description") |> normalize_description() do
      "" ->
        {:error, {:invalid_builtin_skill, :description_required}}

      description ->
        if String.length(description) <= @max_description_length,
          do: {:ok, description},
          else: {:error, {:invalid_builtin_skill, :description_too_long}}
    end
  end

  defp builtin_body(""), do: {:error, {:invalid_builtin_skill, :empty_body}}
  defp builtin_body(_body), do: :ok

  @doc """
  Loads a skill's instructions: its `SKILL.md` body without frontmatter.

  A built-in skill returns its stored content. A file skill is read when called,
  so edits made during a session are seen, through `Tackle.ProjectFiles` with
  the given `:executor` (default: the local executor).
  """
  @spec load(Skill.t(), [{:executor, Executor.t() | nil}]) ::
          {:ok, String.t()} | {:error, term()}
  def load(skill, opts \\ [])

  def load(%Skill{source: :builtin, content: content}, _opts) when is_binary(content),
    do: {:ok, content}

  def load(%Skill{source: :file, path: path}, opts) when is_binary(path) do
    files = ProjectFiles.new(executor: Keyword.get(opts, :executor))

    with {:ok, contents} <- ProjectFiles.read(files, path),
         :ok <- ensure_utf8(contents),
         {:ok, document} <- Frontmatter.parse_document(contents) do
      {:ok, document.body}
    end
  end

  def load(skill, _opts), do: {:error, {:invalid_skill, skill}}

  defp ensure_utf8(contents) do
    if String.valid?(contents), do: :ok, else: {:error, :invalid_utf8}
  end

  @doc """
  Returns the skills offered to an agent with the given tools.

  A skill is available when the agent has every tool its `requires_tools`
  names. `tools` holds tool modules or tool names.
  """
  @spec available([Skill.t()], [module() | String.t()]) :: [Skill.t()]
  def available(skills, tools) when is_list(skills) and is_list(tools) do
    names = MapSet.new(tools, &tool_name/1)
    Enum.filter(skills, fn skill -> Enum.all?(skill.requires_tools, &(&1 in names)) end)
  end

  defp resolve_cwd(nil), do: File.cwd!() |> Path.expand()
  defp resolve_cwd(cwd) when is_binary(cwd), do: Path.expand(cwd)

  @doc """
  Renders visible skills as an `<available_skills>` block for a system prompt.

  Skills with `disable_model_invocation: true` are omitted because they are not
  offered to the model, as are skills whose required tools are missing (see
  `available/2`). Returns an empty string when no skill is visible.

  The `:tools` option is the tool module list being offered to the model. The
  block tells the model to load skills with the `load_skill` tool, so a host
  must offer that tool with the skills, as `Tackle.Config.load/1` does.
  """
  @spec format_for_prompt([Skill.t()], keyword()) :: String.t()
  def format_for_prompt(skills, opts \\ []) when is_list(skills) do
    tools = Keyword.get(opts, :tools, [])

    visible =
      skills
      |> Enum.reject(& &1.disable_model_invocation)
      |> available(tools)

    case visible do
      [] -> ""
      visible -> render(visible)
    end
  end

  defp load_file(files, path, {skills, warnings}) do
    case load_skill(files, path) do
      {:ok, skill, file_warnings} -> {[skill | skills], warnings ++ file_warnings}
      {:error, file_warnings} -> {skills, warnings ++ file_warnings}
    end
  end

  defp load_skill(files, path) do
    with {:ok, contents} <- read(files, path),
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

  defp read(files, path) do
    case ProjectFiles.read(files, path) do
      {:ok, contents} ->
        if String.valid?(contents) do
          {:ok, contents}
        else
          {:error, warning(path, "file is not valid UTF-8")}
        end

      {:error, reason} ->
        {:error, warning(path, "could not be read (#{Executor.format_reason(reason)})")}
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
    {skills, collision_warnings} =
      Enum.reduce(skills, {[], []}, fn skill, {accepted, collision_warnings} ->
        cond do
          skill.source == :file and Enum.any?(accepted, &(&1.path == skill.path)) ->
            {accepted, collision_warnings}

          # A file skill deliberately replaces a built-in skill of the same name.
          skill.source == :builtin and Enum.any?(accepted, &(&1.name == skill.name)) ->
            {accepted, collision_warnings}

          collision = Enum.find(accepted, &(&1.name == skill.name)) ->
            {accepted, [collision_warning(skill, collision) | collision_warnings]}

          true ->
            {[skill | accepted], collision_warnings}
        end
      end)

    %{
      skills: Enum.reverse(skills),
      warnings: warnings ++ Enum.reverse(collision_warnings)
    }
  end

  defp collision_warning(skill, winner) do
    %{
      path: skill.path,
      message: "skill name #{skill.name} is already loaded from #{winner.path}"
    }
  end

  defp warning(path, message), do: %{path: path, message: message}

  defp project_dirs(files, cwd) do
    files
    |> ancestors(cwd)
    |> Enum.map(&Path.join([&1, @agents_dir, @skills_dir]))
  end

  defp global_dirs(opts) do
    case Paths.agents_dir(user_home: Keyword.get(opts, :user_home)) do
      {:ok, agents_dir} -> [Path.join(agents_dir, @skills_dir)]
      {:error, _reason} -> []
    end
  end

  defp ancestors(files, dir) do
    collect_ancestors(dir, ProjectFiles.git_root(files, dir), [])
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

  # A directory holding SKILL.md is a skill; otherwise its children are
  # searched. The walk is bounded (see ProjectFiles.walk/3).
  defp skill_files(files, dir) do
    ProjectFiles.walk(files, dir, fn dir ->
      skill_file = Path.join(dir, @skill_file)

      cond do
        ProjectFiles.regular?(files, skill_file) ->
          [{:file, skill_file}]

        not ProjectFiles.dir?(files, dir) ->
          []

        true ->
          files
          |> children(dir)
          |> Enum.filter(&ProjectFiles.dir?(files, &1))
          |> Enum.map(&{:dir, &1})
      end
    end)
  end

  defp children(files, dir) do
    case ProjectFiles.list(files, dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&ignored?/1)
        |> Enum.map(&Path.join(dir, &1))

      {:error, _reason} ->
        []
    end
  end

  defp ignored?(entry), do: String.starts_with?(entry, ".") or entry in @ignored_entries

  defp render(skills) do
    relative_paths =
      if Enum.any?(skills, &(&1.source == :file)),
        do: [
          "When a skill references a relative path, resolve it against the skill's directory " <>
            "and use that absolute path in tool commands."
        ],
        else: []

    [
      [
        "The following skills provide specialized instructions for specific tasks.",
        "Use the #{LoadSkill.name()} tool to load a skill's instructions when the task " <>
          "matches its description."
      ],
      relative_paths,
      ["", "<available_skills>"],
      Enum.flat_map(skills, &skill_lines/1),
      ["</available_skills>"]
    ]
    |> Enum.concat()
    |> Enum.join("\n")
  end

  defp skill_lines(skill) do
    Enum.concat([
      [
        "  <skill>",
        "    <name>#{escape(skill.name)}</name>",
        "    <description>#{escape(skill.description)}</description>"
      ],
      directory_lines(skill),
      ["  </skill>"]
    ])
  end

  defp directory_lines(%Skill{source: :file, dir: dir}),
    do: ["    <directory>#{escape(dir)}</directory>"]

  defp directory_lines(%Skill{source: :builtin}), do: []

  defp tool_name(tool) when is_atom(tool), do: tool.name()
  defp tool_name(tool) when is_binary(tool), do: tool

  defp escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
