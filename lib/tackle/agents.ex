defmodule Tackle.Agents do
  @moduledoc """
  Discovers declarative subagent profiles from Markdown files.

  User profiles live under `$TACKLE_HOME/agents` and project profiles under the
  nearest `.tackle/agents` directory at or above the working directory, stopping
  at the Git root. Files are discovered recursively. Precedence is built-in,
  then user, then project; a higher-precedence valid definition replaces a
  lower-precedence definition with the same name.

  Files use a deliberately small YAML frontmatter subset followed by the child
  prompt. Configuration is inert: tool strings are resolved separately against
  modules already trusted by the harness.
  """

  alias Tackle.Agents.Definition
  alias Tackle.Paths
  alias Tackle.Skills.Frontmatter

  @known_fields MapSet.new(
                  ~w(name description tools model thinking timeoutMs maxIterations advertise allowDelegation)
                )
  @name_pattern ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/

  @type warning :: %{path: Path.t(), message: String.t()}
  @type discovery :: %{definitions: [Definition.t()], warnings: [warning()]}

  @spec discover(keyword()) :: discovery()
  def discover(opts \\ []) do
    cwd = opts |> Keyword.get_lazy(:cwd, &File.cwd!/0) |> Path.expand()
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
    builtins = Keyword.get(opts, :builtins, [])

    sources =
      [{:builtin, builtins}] ++
        user_source(env) ++ project_source(cwd)

    {definitions, warnings} =
      Enum.reduce(sources, {%{}, []}, fn
        {_source, definitions}, acc when is_list(definitions) ->
          merge_definitions(definitions, acc)

        {source, dir}, acc ->
          load_directory(dir, source, acc)
      end)

    %{
      definitions: definitions |> Map.values() |> Enum.sort_by(& &1.name),
      warnings: warnings
    }
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

  defp user_source(env) do
    case Paths.home(env: env) do
      {:ok, home} -> [{:user, Path.join(home, "agents")}]
      {:error, _reason} -> []
    end
  end

  defp project_source(cwd) do
    case nearest_project_agents(cwd, git_root(cwd)) do
      nil -> []
      dir -> [{:project, dir}]
    end
  end

  defp nearest_project_agents(dir, boundary) do
    candidate = Path.join([dir, ".tackle", "agents"])
    parent = Path.dirname(dir)

    cond do
      File.dir?(candidate) -> candidate
      dir == parent or dir == boundary -> nil
      true -> nearest_project_agents(parent, boundary)
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

  defp load_directory(dir, source, {definitions, warnings}) do
    dir
    |> markdown_files()
    |> Enum.reduce({definitions, warnings}, fn path, {definitions, warnings} ->
      case load_file(path, source) do
        {:ok, definition} ->
          case Map.get(definitions, definition.name) do
            %Definition{source: ^source, path: previous_path} ->
              warning =
                warning(
                  path,
                  "agent name #{definition.name} is already defined in #{previous_path}"
                )

              {definitions, warnings ++ [warning]}

            _other ->
              {Map.put(definitions, definition.name, definition), warnings}
          end

        {:error, message} ->
          {definitions, warnings ++ [warning(path, message)]}
      end
    end)
  end

  defp merge_definitions(new_definitions, {definitions, warnings}) do
    Enum.reduce(new_definitions, {definitions, warnings}, fn definition,
                                                             {definitions, warnings} ->
      {Map.put(definitions, definition.name, definition), warnings}
    end)
  end

  defp markdown_files(dir) do
    cond do
      not File.dir?(dir) -> []
      true -> walk_markdown(dir)
    end
  end

  defp walk_markdown(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.flat_map(fn entry ->
          path = Path.join(dir, entry)

          cond do
            File.dir?(path) -> walk_markdown(path)
            String.ends_with?(entry, ".md") and regular_file?(path) -> [path]
            true -> []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp regular_file?(path) do
    match?({:ok, %File.Stat{type: :regular}}, File.stat(path))
  end

  defp load_file(path, source) do
    with {:ok, contents} <- read(path),
         {:ok, document} <- Frontmatter.parse_document(contents),
         :ok <- validate_fields(document.frontmatter),
         {:ok, definition} <- build(path, source, document.frontmatter, document.body) do
      {:ok, definition}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "malformed frontmatter (#{inspect(reason)})"}

      {:error, message} ->
        {:error, message}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, contents} ->
        if String.valid?(contents), do: {:ok, contents}, else: {:error, "file is not valid UTF-8"}

      {:error, reason} ->
        {:error, "could not be read (#{:file.format_error(reason)})"}
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
         {:ok, timeout} <- positive_integer(frontmatter, "timeoutMs", :timer.minutes(5)),
         {:ok, max_iterations} <- positive_integer(frontmatter, "maxIterations", 20),
         {:ok, advertise} <- boolean(frontmatter, "advertise", false),
         {:ok, allow_delegation} <- boolean(frontmatter, "allowDelegation", false),
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
         allow_delegation: allow_delegation
       }}
    end
  end

  defp required_string(frontmatter, key) do
    case Map.get(frontmatter, key) do
      value when is_binary(value) and value != "" -> {:ok, String.trim(value)}
      _other -> {:error, "#{key} is required"}
    end
  end

  defp optional_string(frontmatter, key) do
    case Map.get(frontmatter, key) do
      nil -> {:ok, nil}
      value when is_binary(value) and value != "" -> {:ok, String.trim(value)}
      value -> {:error, "#{key} must be a non-empty string, got: #{inspect(value)}"}
    end
  end

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
    value = String.trim(value)

    value =
      if String.starts_with?(value, "[") and String.ends_with?(value, "]"),
        do: String.slice(value, 1, byte_size(value) - 2),
        else: value

    names =
      value
      |> String.split([",", "\n"], trim: true)
      |> Enum.map(&(String.trim(&1) |> String.trim_leading("- ")))
      |> Enum.reject(&(&1 == ""))

    if length(names) == MapSet.size(MapSet.new(names)),
      do: {:ok, names},
      else: {:error, "tools contains duplicate names"}
  end

  defp tools(value),
    do: {:error, "tools must be a comma-separated or block list, got: #{inspect(value)}"}

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

  defp warning(path, message), do: %{path: path, message: message}

  defp escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
