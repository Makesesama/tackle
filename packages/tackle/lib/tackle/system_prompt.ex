defmodule Tackle.SystemPrompt do
  @moduledoc """
  Builds the developer harness system prompt and loads instruction files.

  The prompt is composed in this order:

    1. an explicit base prompt, `$TACKLE_HOME/SYSTEM.md`, or the built-in prompt;
    2. `$TACKLE_HOME/APPEND_SYSTEM.md`, when present;
    3. `$TACKLE_HOME/AGENTS.md` and the `AGENTS.md` files of the working
       directory and its ancestors, broadest first: up to the home directory
       when the working directory is under it, otherwise up to the Git root,
       or only the working directory outside a Git repository (see
       `Tackle.ProjectFiles.ancestors/3`);
    4. available Agent Skills from `.agents/skills`, when present; and
    5. the current working directory.

  With `instructions: false`, steps 2 and 3 are skipped and their files are
  not read, so the prompt holds only the base, the given skills, and the
  working directory.

  Missing optional files are ignored. Unreadable or invalid UTF-8 files return
  explicit errors so a session never starts with silently incomplete guidance.
  """

  alias Tackle.{Executor, ProjectFiles, Skills}
  alias Tackle.Lib.SystemPrompt, as: PromptBuilder

  @type build_option ::
          {:base, String.t() | nil}
          | {:cwd, Path.t()}
          | {:home, Path.t()}
          | {:user_home, Path.t() | nil}
          | {:tools, [module()]}
          | {:skills, [Skills.Skill.t()]}
          | {:executor, Executor.t()}
          | {:instructions, boolean()}

  @typedoc """
  The prompt files `read/1` read, each as the result of reading it, so that a
  file only fails a prompt that uses it: `$TACKLE_HOME/SYSTEM.md` (`nil` when
  missing), `APPEND_SYSTEM.md` (`nil` when missing or not read), and the
  `AGENTS.md` files in prompt order (`[]` when not read).
  """
  @type files :: %{
          system: {:ok, String.t() | nil} | {:error, term()},
          append: {:ok, String.t() | nil} | {:error, term()},
          context_files: {:ok, [%{path: Path.t(), content: String.t()}]} | {:error, term()}
        }

  @doc "Builds the effective system prompt for one configured session."
  @spec build([build_option()]) :: {:ok, String.t()} | {:error, term()}
  def build(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         {:ok, files} <-
           opts
           |> Keyword.take([:cwd, :home, :user_home, :executor, :instructions])
           |> Keyword.put(:system, not is_binary(Keyword.get(opts, :base)))
           |> read() do
      compose(files, opts)
    else
      false -> {:error, {:invalid_system_prompt_options, opts}}
      {:error, reason} -> {:error, reason}
    end
  end

  def build(opts), do: {:error, {:invalid_system_prompt_options, opts}}

  @doc """
  Reads the prompt files for `:cwd` and `:home` through `:executor`.

  `:user_home` (default: the operating-system home, `nil` for none) bounds
  the `AGENTS.md` search (see `Tackle.ProjectFiles.ancestors/3`).

  `instructions: false` (default `true`) leaves `APPEND_SYSTEM.md` and the
  `AGENTS.md` files unread, and `system: false` (default `true`) `SYSTEM.md`.
  A file that cannot be read is kept as its error (see `t:files/0`).
  """
  @spec read(keyword()) :: {:ok, files()} | {:error, term()}
  def read(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         {:ok, cwd} <- fetch_path(opts, :cwd),
         {:ok, home} <- fetch_path(opts, :home),
         {:ok, instructions} <- fetch_boolean(opts, :instructions),
         {:ok, system} <- fetch_boolean(opts, :system) do
      files = ProjectFiles.new(Keyword.take(opts, [:executor, :user_home]))

      {:ok,
       %{
         system:
           if(system, do: read_optional(files, Path.join(home, "SYSTEM.md")), else: {:ok, nil}),
         append:
           if(instructions,
             do: read_optional(files, Path.join(home, "APPEND_SYSTEM.md")),
             else: {:ok, nil}
           ),
         context_files:
           if(instructions, do: load_context_files(files, cwd, home), else: {:ok, []})
       }}
    else
      false -> {:error, {:invalid_system_prompt_options, opts}}
      {:error, reason} -> {:error, reason}
    end
  end

  def read(opts), do: {:error, {:invalid_system_prompt_options, opts}}

  @doc """
  Composes the prompt from files `read/1` read, without reading anything.

  Takes `build/1`'s options except `:home`, `:user_home`, and `:executor`. With
  `instructions: true`, the files must have been read with instructions.
  """
  @spec compose(files(), [build_option()]) :: {:ok, String.t()} | {:error, term()}
  def compose(files, opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         {:ok, cwd} <- fetch_path(opts, :cwd),
         {:ok, tools} <- fetch_tools(opts),
         {:ok, instructions} <- fetch_boolean(opts, :instructions),
         {:ok, base} <- resolve_base(files, Keyword.get(opts, :base), tools),
         {:ok, skills} <- fetch_skills(opts),
         {:ok, append, context_files} <- instructions(files, instructions) do
      prompt =
        PromptBuilder.new()
        |> PromptBuilder.add_raw(base)
        |> add_optional(append)
        |> add_context(context_files)
        |> add_skills(skills, tools)
        |> PromptBuilder.add_raw("Current working directory: #{cwd}")
        |> PromptBuilder.to_string()

      {:ok, prompt}
    else
      false -> {:error, {:invalid_system_prompt_options, opts}}
      {:error, reason} -> {:error, reason}
    end
  end

  def compose(_files, opts), do: {:error, {:invalid_system_prompt_options, opts}}

  defp fetch_path(opts, name) do
    case Keyword.fetch(opts, name) do
      {:ok, path} when is_binary(path) -> {:ok, Path.expand(path)}
      {:ok, path} -> {:error, {:invalid_system_prompt_option, name, path}}
      :error -> {:error, {:missing_system_prompt_option, name}}
    end
  end

  defp fetch_tools(opts) do
    case Keyword.get(opts, :tools, []) do
      tools when is_list(tools) -> {:ok, tools}
      tools -> {:error, {:invalid_system_prompt_option, :tools, tools}}
    end
  end

  defp fetch_boolean(opts, name) do
    case Keyword.get(opts, name, true) do
      value when is_boolean(value) -> {:ok, value}
      other -> {:error, {:invalid_system_prompt_option, name, other}}
    end
  end

  defp instructions(_files, false), do: {:ok, nil, []}

  defp instructions(%{append: append, context_files: context_files}, true) do
    with {:ok, append} <- append,
         {:ok, context_files} <- context_files do
      {:ok, append, context_files}
    end
  end

  defp fetch_skills(opts) do
    case Keyword.get(opts, :skills, []) do
      skills when is_list(skills) -> {:ok, skills}
      skills -> {:error, {:invalid_system_prompt_option, :skills, skills}}
    end
  end

  defp resolve_base(_files, base, _tools) when is_binary(base), do: {:ok, base}

  defp resolve_base(%{system: system}, nil, tools) do
    case system do
      {:ok, nil} -> {:ok, default(tools)}
      {:ok, prompt} -> {:ok, prompt}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_base(_files, base, _tools),
    do: {:error, {:invalid_system_prompt_option, :base, base}}

  @doc "Returns the built-in coding prompt for a validated tool set."
  @spec default([module()]) :: String.t()
  def default(tools) when is_list(tools) do
    tools_list =
      case tools do
        [] ->
          "(none)"

        tools ->
          Enum.map_join(tools, "\n", fn tool ->
            "- #{tool.name()}: #{tool.description()}"
          end)
      end

    guidelines =
      tools
      |> Enum.map(& &1.name())
      |> tool_guidelines()
      |> Kernel.++([
        "Preserve existing user changes and keep edits focused on the request.",
        "Be concise in your responses.",
        "Show file paths clearly when working with files."
      ])
      |> Enum.map_join("\n", &"- #{&1}")

    """
    You are an expert coding assistant operating inside Tackle, an Elixir developer agent harness. You help users by reading files, executing commands, editing code, and writing new files.

    Available tools:
    #{tools_list}

    Guidelines:
    #{guidelines}
    """
    |> String.trim()
  end

  defp tool_guidelines(tool_names) do
    tool_names = MapSet.new(tool_names)

    [
      {MapSet.member?(tool_names, "bash"),
       "Use bash for file operations such as listing, searching, and finding files."},
      {MapSet.member?(tool_names, "read") and MapSet.member?(tool_names, "edit"),
       "Use read to examine file contents and edit for precise changes."}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp load_context_files(files, cwd, home) do
    paths =
      [
        Path.join(home, "AGENTS.md")
        | files
          |> ProjectFiles.ancestors(cwd, beyond_git_root: true)
          |> Enum.reverse()
          |> Enum.map(&Path.join(&1, "AGENTS.md"))
      ]
      |> Enum.uniq()

    paths
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, loaded} ->
      case read_optional(files, path) do
        {:ok, nil} -> {:cont, {:ok, loaded}}
        {:ok, content} -> {:cont, {:ok, [%{path: path, content: content} | loaded]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_context_files()
  end

  defp reverse_context_files({:ok, files}), do: {:ok, Enum.reverse(files)}
  defp reverse_context_files({:error, reason}), do: {:error, reason}

  defp add_optional(prompt, nil), do: prompt
  defp add_optional(prompt, content), do: PromptBuilder.add_raw(prompt, content)

  defp add_skills(prompt, [], _tools), do: prompt

  defp add_skills(prompt, skills, tools) do
    case Skills.format_for_prompt(skills, tools: tools) do
      "" -> prompt
      section -> PromptBuilder.add_raw(prompt, section)
    end
  end

  defp add_context(prompt, []), do: prompt

  defp add_context(prompt, files) do
    body =
      files
      |> Enum.map_join("\n\n", fn %{path: path, content: content} ->
        "<project_instructions path=\"#{escape_attribute(path)}\">\n#{String.trim(content)}\n</project_instructions>"
      end)

    PromptBuilder.add_raw(
      prompt,
      """
      <project_context>

      Project-specific instructions and guidelines:

      #{body}

      </project_context>
      """
    )
  end

  defp read_optional(files, path) do
    case ProjectFiles.type(files, path) do
      {:ok, :regular} -> read_prompt_file(files, path)
      {:ok, _type} -> {:ok, nil}
      {:error, :enoent} -> {:ok, nil}
      {:error, reason} -> {:error, {:system_prompt_file_unreadable, path, reason}}
    end
  end

  defp read_prompt_file(files, path) do
    case ProjectFiles.read(files, path) do
      {:ok, content} -> validate_content(path, strip_bom(content))
      {:error, reason} -> {:error, {:system_prompt_file_unreadable, path, reason}}
    end
  end

  defp validate_content(path, content) do
    if String.valid?(content) do
      {:ok, content}
    else
      {:error, {:invalid_system_prompt_file, path, :invalid_utf8}}
    end
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, content::binary>>), do: content
  defp strip_bom(content), do: content

  defp escape_attribute(path) do
    path
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
