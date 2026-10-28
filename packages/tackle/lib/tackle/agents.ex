defmodule Tackle.Agents do
  @moduledoc """
  Discovers declarative subagent profiles from Markdown files.

  User profiles live under `$TACKLE_HOME/agents` and project profiles under the
  nearest `.tackle/agents` directory at or above the working directory, within
  the bounds of `Tackle.ProjectFiles.ancestors/3`; `$TACKLE_HOME` itself is
  never a project directory. Files are discovered recursively. Precedence is
  built-in, then user, then project; a higher-precedence valid definition
  replaces a lower-precedence definition with the same name.

  Files use a deliberately small YAML frontmatter subset followed by the child
  prompt. Configuration is inert: tool strings are resolved separately against
  modules already trusted by the harness. `tools` is a list in the forms of
  `YamlFrontmatter.list/1`; an empty value leaves it unset. `timeoutMs` is at
  most five minutes.
  """

  alias Tackle.Agents.Definition
  alias Tackle.{Paths, ProjectFiles}
  alias YamlFrontmatter, as: Frontmatter

  @known_fields MapSet.new(
                  ~w(name description tools model thinking timeoutMs maxIterations advertise allowDelegation instructions)
                )
  @name_pattern ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/
  @max_timeout :timer.minutes(5)

  @typedoc "A definition file that could not be loaded, and why."
  @type problem :: %{path: Path.t(), message: String.t()}

  @typedoc """
  `discover/1` options:

    * `:cwd` - the working directory the project search starts from
      (default: the current directory);
    * `:executor` - the session executor workspace files are read through
      (see `Tackle.ProjectFiles`; default: the local executor);
    * `:home` and `:user_home` - the Tackle home holding the user profiles
      and the user's home directory bounding the project search, `nil` for
      none (default: resolved from the process environment, see
      `Tackle.Paths.homes/1`);
    * `:builtins` - the host's built-in definitions, lowest precedence
      (default: none; `Tackle.Coding` passes `Tackle.Agents.Default.definitions/0`).
  """
  @type option ::
          {:cwd, Path.t()}
          | {:executor, Tackle.Executor.t() | nil}
          | {:home, Path.t() | nil}
          | {:user_home, Path.t() | nil}
          | {:builtins, [Definition.t()]}

  @doc """
  Discovers the built-in, user, and project definitions (see the module
  documentation), sorted by name.

  Every file must load: a file that cannot be read, malformed front matter,
  an unknown or invalid field, or a name defined twice in one source is a
  problem, and any problem is `{:error, {:invalid_agent_definitions,
  problems}}`, so a session never starts with a profile silently missing.
  """
  @spec discover([option()]) ::
          {:ok, [Definition.t()]} | {:error, {:invalid_agent_definitions, [problem()]}}
  def discover(opts \\ []) do
    cwd = opts |> Keyword.get_lazy(:cwd, &File.cwd!/0) |> Path.expand()
    homes = opts |> Keyword.take([:home, :user_home]) |> Paths.homes()
    files = ProjectFiles.new(executor: Keyword.get(opts, :executor), user_home: homes[:user_home])

    loaded =
      files
      |> ProjectFiles.tackle_dirs(cwd, homes[:home], "agents")
      |> Enum.flat_map(fn {source, dir} ->
        Enum.map(markdown_files(files, dir), &load_file(files, &1, source))
      end)

    {definitions, problems} =
      opts
      |> Keyword.get(:builtins, [])
      |> Enum.map(&{:ok, &1})
      |> Enum.concat(loaded)
      |> Enum.reduce({%{}, []}, &merge/2)

    case problems do
      [] -> {:ok, definitions |> Map.values() |> Enum.sort_by(& &1.name)}
      problems -> {:error, {:invalid_agent_definitions, Enum.reverse(problems)}}
    end
  end

  @doc "Renders advertised profiles for the root agent's prompt."
  @spec format_for_prompt([Definition.t()]) :: String.t()
  def format_for_prompt(definitions) when is_list(definitions) do
    advertised = definitions |> Enum.filter(& &1.advertise) |> Enum.sort_by(& &1.name)

    case advertised do
      [] ->
        ""

      definitions ->
        entries =
          Enum.flat_map(definitions, fn definition ->
            [
              "  <subagent>",
              "    <name>#{escape(definition.name)}</name>",
              "    <description>#{escape(definition.description)}</description>",
              "  </subagent>"
            ]
          end)

        Enum.join(["<available_subagents>" | entries] ++ ["</available_subagents>"], "\n")
    end
  end

  # A later source replaces an earlier definition of the same name; a file
  # source defining a name twice is a problem.
  defp merge({:ok, definition}, {definitions, problems}) do
    case Map.get(definitions, definition.name) do
      %Definition{source: source, path: previous}
      when source == definition.source and source != :builtin ->
        message = "agent name #{definition.name} is already defined in #{previous}"
        {definitions, [problem(definition.path, message) | problems]}

      _other ->
        {Map.put(definitions, definition.name, definition), problems}
    end
  end

  defp merge({:error, problem}, {definitions, problems}), do: {definitions, [problem | problems]}

  defp markdown_files(files, dir) do
    if ProjectFiles.dir?(files, dir),
      do: ProjectFiles.walk(files, dir, &markdown_entries(files, &1)),
      else: []
  end

  # Bounded depth-first walk (see ProjectFiles.walk/3) over non-hidden entries.
  defp markdown_entries(files, dir) do
    case ProjectFiles.list(files, dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.flat_map(&markdown_entry(files, dir, &1))

      {:error, _reason} ->
        []
    end
  end

  defp markdown_entry(files, dir, entry) do
    path = Path.join(dir, entry)

    cond do
      ProjectFiles.dir?(files, path) -> [{:dir, path}]
      String.ends_with?(entry, ".md") and ProjectFiles.regular?(files, path) -> [{:file, path}]
      true -> []
    end
  end

  defp load_file(files, path, source) do
    with {:ok, contents} <- read(files, path),
         {:ok, document} <- Frontmatter.parse_document(contents),
         :ok <- validate_fields(document.frontmatter),
         {:ok, definition} <- build(path, source, document.frontmatter, document.body) do
      {:ok, definition}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, problem(path, "malformed frontmatter (#{inspect(reason)})")}

      {:error, message} ->
        {:error, problem(path, message)}
    end
  end

  defp read(files, path) do
    case ProjectFiles.read_text(files, path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, "could not be read (#{ProjectFiles.format_error(reason)})"}
    end
  end

  defp validate_fields(frontmatter) do
    unknown =
      frontmatter |> Map.keys() |> Enum.reject(&MapSet.member?(@known_fields, &1)) |> Enum.sort()

    if unknown == [],
      do: :ok,
      else: {:error, "unknown frontmatter fields: #{Enum.join(unknown, ", ")}"}
  end

  defp build(path, source, frontmatter, body) do
    with {:ok, name} <- required_string(frontmatter, "name"),
         :ok <- validate_name(name),
         {:ok, description} <- required_string(frontmatter, "description"),
         {:ok, tools} <- tools(Map.get(frontmatter, "tools")),
         {:ok, model} <- optional_string(frontmatter, "model"),
         {:ok, thinking} <- optional_string(frontmatter, "thinking"),
         :ok <- validate_thinking_model(thinking, model),
         {:ok, timeout} <- positive_integer(frontmatter, "timeoutMs", @max_timeout),
         :ok <- validate_timeout(name, timeout),
         {:ok, max_iterations} <- positive_integer(frontmatter, "maxIterations", :infinity),
         {:ok, advertise} <- boolean(frontmatter, "advertise", false),
         {:ok, allow_delegation} <- boolean(frontmatter, "allowDelegation", false),
         {:ok, instructions} <- boolean(frontmatter, "instructions", true),
         :ok <- nonempty_prompt(body) do
      {:ok,
       %Definition{
         name: name,
         description: normalize_space(description),
         prompt: body,
         source: source,
         path: path,
         tools: tools,
         model: model,
         thinking: thinking,
         timeout: timeout,
         max_iterations: max_iterations,
         advertise: advertise,
         allow_delegation: allow_delegation,
         instructions: instructions
       }}
    end
  end

  defp required_string(frontmatter, key) do
    case frontmatter |> Map.get(key) |> trimmed() do
      "" -> {:error, "#{key} is required"}
      value -> {:ok, value}
    end
  end

  defp optional_string(frontmatter, key) do
    case Map.get(frontmatter, key) do
      nil ->
        {:ok, nil}

      value ->
        case trimmed(value) do
          "" -> {:error, "#{key} must be a non-empty string, got: #{inspect(value)}"}
          value -> {:ok, value}
        end
    end
  end

  defp trimmed(value) when is_binary(value), do: String.trim(value)
  defp trimmed(_value), do: ""

  defp validate_name(name) do
    if Regex.match?(@name_pattern, name),
      do: :ok,
      else: {:error, "name must use lowercase letters, numbers, and single hyphens"}
  end

  defp validate_thinking_model(nil, _model), do: :ok
  defp validate_thinking_model(_thinking, model) when is_binary(model), do: :ok

  defp validate_thinking_model(_thinking, nil),
    do: {:error, "thinking requires an explicit model"}

  defp tools(nil), do: {:ok, nil}

  defp tools(value) when is_binary(value) do
    if String.trim(value) == "",
      do: {:ok, nil},
      else: value |> Frontmatter.list() |> tool_names(value)
  end

  defp tools(value), do: tools_error(value)

  defp tool_names({:ok, names}, _value) do
    if length(names) == MapSet.size(MapSet.new(names)),
      do: {:ok, names},
      else: {:error, "tools contains duplicate names"}
  end

  defp tool_names({:error, _reason}, value), do: tools_error(value)

  defp tools_error(value),
    do: {:error, "tools must be a flow, block, or comma-separated list, got: #{inspect(value)}"}

  defp validate_timeout(_name, timeout) when timeout <= @max_timeout, do: :ok

  defp validate_timeout(name, timeout) do
    {:error,
     "timeoutMs of agent #{name} is #{timeout}; the limit is #{@max_timeout} (five minutes)"}
  end

  defp positive_integer(frontmatter, key, default) do
    case Map.get(frontmatter, key) do
      nil ->
        {:ok, default}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} when integer > 0 -> {:ok, integer}
          _other -> {:error, "#{key} must be a positive integer"}
        end

      value ->
        {:error, "#{key} must be a positive integer, got: #{inspect(value)}"}
    end
  end

  defp boolean(frontmatter, key, default) do
    case Map.get(frontmatter, key) do
      nil -> {:ok, default}
      value when is_boolean(value) -> {:ok, value}
      value -> {:error, "#{key} must be true or false, got: #{inspect(value)}"}
    end
  end

  defp nonempty_prompt(body),
    do: if(String.trim(body) == "", do: {:error, "agent prompt is required"}, else: :ok)

  defp normalize_space(value), do: value |> String.split(~r/\s+/u, trim: true) |> Enum.join(" ")

  defp problem(path, message), do: %{path: path, message: message}

  defp escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
