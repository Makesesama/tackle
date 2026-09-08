defmodule Tackle.SystemPrompt do
  @moduledoc """
  Builds the developer harness system prompt and loads instruction files.

  The prompt is composed in this order:

    1. an explicit base prompt, `$TACKLE_HOME/SYSTEM.md`, or the built-in prompt;
    2. `$TACKLE_HOME/APPEND_SYSTEM.md`, when present;
    3. `$TACKLE_HOME/AGENTS.md` and `AGENTS.md` files from filesystem root to
       the current working directory; and
    4. the current working directory.

  Missing optional files are ignored. Unreadable or invalid UTF-8 files return
  explicit errors so a session never starts with silently incomplete guidance.
  """

  alias Tackle.Lib.SystemPrompt, as: PromptBuilder

  @type build_option ::
          {:base, String.t() | nil}
          | {:cwd, Path.t()}
          | {:home, Path.t()}
          | {:tools, [module()]}

  @doc "Builds the effective system prompt for one configured session."
  @spec build([build_option()]) :: {:ok, String.t()} | {:error, term()}
  def build(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         {:ok, cwd} <- fetch_path(opts, :cwd),
         {:ok, home} <- fetch_path(opts, :home),
         {:ok, tools} <- fetch_tools(opts),
         {:ok, base} <- resolve_base(Keyword.get(opts, :base), home, tools),
         {:ok, append} <- read_optional(Path.join(home, "APPEND_SYSTEM.md")),
         {:ok, context_files} <- load_context_files(cwd, home) do
      prompt =
        PromptBuilder.new()
        |> PromptBuilder.add_raw(base)
        |> add_optional(append)
        |> add_context(context_files)
        |> PromptBuilder.add_raw("Current working directory: #{cwd}")
        |> PromptBuilder.to_string()

      {:ok, prompt}
    else
      false -> {:error, {:invalid_system_prompt_options, opts}}
      {:error, reason} -> {:error, reason}
    end
  end

  def build(opts), do: {:error, {:invalid_system_prompt_options, opts}}

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

  defp resolve_base(base, _home, _tools) when is_binary(base), do: {:ok, base}

  defp resolve_base(nil, home, tools) do
    case read_optional(Path.join(home, "SYSTEM.md")) do
      {:ok, nil} -> {:ok, default(tools)}
      {:ok, prompt} -> {:ok, prompt}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_base(base, _home, _tools),
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

    []
    |> maybe_add_guideline(
      MapSet.member?(tool_names, "bash"),
      "Use bash for file operations such as listing, searching, and finding files."
    )
    |> maybe_add_guideline(
      MapSet.member?(tool_names, "read") and MapSet.member?(tool_names, "edit"),
      "Use read to examine file contents and edit for precise changes."
    )
  end

  defp maybe_add_guideline(guidelines, true, guideline), do: guidelines ++ [guideline]
  defp maybe_add_guideline(guidelines, false, _guideline), do: guidelines

  defp load_context_files(cwd, home) do
    paths =
      [
        Path.join(home, "AGENTS.md")
        | Enum.map(ancestor_directories(cwd), &Path.join(&1, "AGENTS.md"))
      ]
      |> Enum.uniq()

    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, files} ->
      case read_optional(path) do
        {:ok, nil} -> {:cont, {:ok, files}}
        {:ok, content} -> {:cont, {:ok, files ++ [%{path: path, content: content}]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp ancestor_directories(cwd), do: ancestor_directories(cwd, [])

  defp ancestor_directories(directory, directories) do
    parent = Path.dirname(directory)
    directories = [directory | directories]

    if parent == directory do
      directories
    else
      ancestor_directories(parent, directories)
    end
  end

  defp add_optional(prompt, nil), do: prompt
  defp add_optional(prompt, content), do: PromptBuilder.add_raw(prompt, content)

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

  defp read_optional(path) do
    case File.stat(path) do
      {:ok, %{type: :regular}} -> read_prompt_file(path)
      {:ok, _stat} -> {:ok, nil}
      {:error, :enoent} -> {:ok, nil}
      {:error, reason} -> {:error, {:system_prompt_file_unreadable, path, reason}}
    end
  end

  defp read_prompt_file(path) do
    case File.read(path) do
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
