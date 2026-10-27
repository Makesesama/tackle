defmodule Tackle.CLI.MCP.Config do
  @moduledoc false

  # MCP server definitions come from two layers:
  #
  #   * user: `$TACKLE_HOME/mcp.json`, trusted because only the user writes it;
  #   * project: `mcp.json` in the nearest `.tackle` directory at or above the
  #     working directory (within `Tackle.ProjectFiles.ancestors/3`), usually
  #     committed.
  #
  # Both use `{"version": 1, "servers": {NAME => definition}}`. A project
  # definition replaces a user definition with the same name. Project servers
  # can run arbitrary host commands, so a project definition is only enabled
  # after the user approves that exact definition (`tackle mcp approve NAME`).
  # Approvals live in `$TACKLE_HOME/mcp-approvals.json`, keyed by the project
  # file path, the server name and a SHA-256 fingerprint of the definition, so
  # a repository cannot approve its own servers and any edit needs re-approval.

  alias Tackle.ProjectFiles

  @name ~r/\A[A-Za-z0-9_-]{1,32}\z/

  @type scope :: :user | :project
  @type entry :: %{
          name: String.t(),
          scope: scope(),
          definition: map(),
          spec: map(),
          path: Path.t(),
          approved: boolean()
        }

  def path do
    with {:ok, home} <- Tackle.Paths.home(), do: {:ok, Path.join(home, "mcp.json")}
  end

  def approvals_path do
    with {:ok, home} <- Tackle.Paths.home(), do: {:ok, Path.join(home, "mcp-approvals.json")}
  end

  def list do
    with {:ok, path} <- path(),
         :ok <- safe_target(path) do
      case File.read(path) do
        {:error, :enoent} -> {:ok, %{}}
        {:ok, data} -> decode(data)
        {:error, reason} -> {:error, {:mcp_config_unreadable, reason}}
      end
    end
  end

  def put(name, definition) do
    with :ok <- valid_name(name),
         :ok <- valid_definition(definition),
         {:ok, servers} <- list(),
         false <- Map.has_key?(servers, name),
         {:ok, path} <- path() do
      persist(path, Map.put(servers, name, definition), :private)
    else
      true -> {:error, :mcp_server_exists}
      error -> error
    end
  end

  def remove(name) do
    with :ok <- valid_name(name),
         {:ok, servers} <- list(),
         true <- Map.has_key?(servers, name),
         {:ok, path} <- path() do
      persist(path, Map.delete(servers, name), :private)
    else
      false -> {:error, :mcp_server_missing}
      error -> error
    end
  end

  @doc """
  Locates the project layer for `opts[:cwd]` (default: the current directory).

  Returns `{:ok, %{path: mcp_json, root: project_root, files: files}}`, or
  `:none` when the nearest `.tackle` directory is `$TACKLE_HOME` itself.
  Without any `.tackle` directory, the path is `.tackle/mcp.json` in the Git
  root, or in the working directory outside a Git repository.
  """
  def project(opts \\ []) do
    cwd = opts |> Keyword.get_lazy(:cwd, &File.cwd!/0) |> Path.expand()
    files = ProjectFiles.new(executor: Keyword.get(opts, :executor))

    with {:ok, home} <- Tackle.Paths.home() do
      dir =
        ProjectFiles.nearest_project_dir(files, cwd, ".tackle") ||
          Path.join(ProjectFiles.git_root(files, cwd) || cwd, ".tackle")

      if ProjectFiles.same_dir?(dir, home),
        do: :none,
        else: {:ok, %{path: Path.join(dir, "mcp.json"), root: Path.dirname(dir), files: files}}
    end
  end

  @doc "Reads the project layer; `{:ok, nil}` when there is none."
  def list_project(opts \\ []) do
    case project(opts) do
      :none ->
        {:ok, nil}

      {:ok, project} ->
        case ProjectFiles.read(project.files, project.path) do
          {:error, :enoent} ->
            {:ok, Map.put(project, :servers, %{})}

          {:ok, data} ->
            case decode(data) do
              {:ok, servers} -> {:ok, Map.put(project, :servers, servers)}
              {:error, _} -> {:error, {:invalid_project_mcp_config, project.path}}
            end

          {:error, reason} ->
            {:error, {:project_mcp_config_unreadable, project.path, reason}}
        end

      error ->
        error
    end
  end

  @doc """
  Returns the configured servers, sorted by name.

  An approved project definition replaces a user definition with the same
  name. A project definition that is not approved never replaces one: it is
  listed next to the user entry, with `approved: false`, so a repository cannot
  disable a user's server by declaring its name. Callers that connect use
  only `approved` entries, of which there is at most one per name.

  `spec` is the definition used to connect: project STDIO servers carry a
  `"cwd"` of the project root. Options:

    * `:project` - `false` ignores the project layer.
    * `:jailed` - `true` blocks project STDIO servers (`blocked: :jailed`):
      they run on the host from files the jailed agent can rewrite.
  """
  @spec effective(keyword()) :: {:ok, [entry()]} | {:error, term()}
  def effective(opts \\ []) do
    with {:ok, user} <- list(),
         {:ok, user_path} <- path(),
         {:ok, project} <-
           if(Keyword.get(opts, :project, true), do: list_project(opts), else: {:ok, nil}),
         {:ok, approvals} <- approvals() do
      user_entries =
        Map.new(user, fn {name, definition} ->
          {name,
           %{
             name: name,
             scope: :user,
             definition: definition,
             spec: definition,
             path: user_path,
             approved: true
           }}
        end)

      project_entries =
        if project do
          Map.new(project.servers, fn {name, definition} ->
            {name,
             %{
               name: name,
               scope: :project,
               definition: definition,
               spec: project_spec(definition, project.root),
               path: project.path,
               approved: approved?(approvals, project.path, name, definition)
             }
             |> block_jailed(Keyword.get(opts, :jailed, false))}
          end)
        else
          %{}
        end

      active = for {name, %{approved: true}} <- project_entries, into: %{}, do: {name, true}
      pending = for {_name, %{approved: false} = entry} <- project_entries, do: entry

      {:ok,
       (Map.values(Map.merge(user_entries, Map.take(project_entries, Map.keys(active)))) ++
          pending)
       |> Enum.sort_by(&{&1.name, &1.scope != :user})}
    end
  end

  @doc """
  Like `effective/1`, but an unreadable or invalid project layer falls back to
  the user layer and is reported as `{:ok, entries, warning}`.
  """
  @spec effective_or_user(keyword()) :: {:ok, [entry()], String.t() | nil} | {:error, term()}
  def effective_or_user(opts \\ []) do
    case effective(opts) do
      {:ok, entries} ->
        {:ok, entries, nil}

      {:error, reason} = error ->
        case project_warning(reason) do
          nil ->
            error

          warning ->
            with {:ok, entries} <- effective(Keyword.put(opts, :project, false)),
                 do: {:ok, entries, warning}
        end
    end
  end

  @doc "Describes a project layer error, or returns `nil` for other errors."
  def project_warning({:invalid_project_mcp_config, path}),
    do: "Ignoring project MCP servers in #{path}: invalid config"

  def project_warning({:project_mcp_config_unreadable, path, reason}),
    do: "Ignoring project MCP servers in #{path}: #{inspect(reason)}"

  def project_warning(_reason), do: nil

  defp block_jailed(%{definition: %{"transport" => "stdio"}} = entry, true),
    do: Map.merge(entry, %{approved: false, blocked: :jailed})

  defp block_jailed(entry, _jailed), do: entry

  defp project_spec(%{"transport" => "stdio"} = definition, root),
    do: Map.put(definition, "cwd", root)

  defp project_spec(definition, _root), do: definition

  @doc "Adds a definition to the project layer."
  def put_project(name, definition, opts \\ []) do
    with :ok <- valid_name(name),
         :ok <- valid_definition(definition),
         {:ok, project} <- writable_project(opts),
         false <- Map.has_key?(project.servers, name),
         :ok <- persist(project.path, Map.put(project.servers, name, definition), :shared) do
      {:ok, project.path}
    else
      true -> {:error, :mcp_server_exists}
      error -> error
    end
  end

  @doc "Removes a definition from the project layer."
  def remove_project(name, opts \\ []) do
    with :ok <- valid_name(name),
         {:ok, project} <- writable_project(opts),
         true <- Map.has_key?(project.servers, name),
         :ok <- persist(project.path, Map.delete(project.servers, name), :shared) do
      {:ok, project.path}
    else
      false -> {:error, :mcp_server_missing}
      error -> error
    end
  end

  defp writable_project(opts) do
    case list_project(opts) do
      {:ok, nil} -> {:error, :no_mcp_project}
      result -> result
    end
  end

  def approvals do
    with {:ok, path} <- approvals_path(),
         :ok <- safe_target(path) do
      case File.read(path) do
        {:error, :enoent} -> {:ok, %{}}
        {:ok, data} -> decode_approvals(data)
        {:error, reason} -> {:error, {:mcp_approvals_unreadable, reason}}
      end
    end
  end

  @doc "Approves this exact project definition for `project_path`."
  def approve(project_path, name, definition) do
    update_approvals(fn approvals ->
      Map.update(
        approvals,
        project_path,
        %{name => fingerprint(definition)},
        &Map.put(&1, name, fingerprint(definition))
      )
    end)
  end

  @doc "Forgets the approval of a project server."
  def revoke(project_path, name) do
    update_approvals(fn approvals ->
      case Map.get(approvals, project_path) do
        nil ->
          approvals

        servers ->
          servers = Map.delete(servers, name)

          if servers == %{},
            do: Map.delete(approvals, project_path),
            else: Map.put(approvals, project_path, servers)
      end
    end)
  end

  def approved?(approvals, project_path, name, definition),
    do: get_in(approvals, [project_path, name]) == fingerprint(definition)

  @doc "A stable SHA-256 fingerprint of a definition, independent of key order."
  def fingerprint(definition) do
    canonical = definition |> Enum.sort() |> Enum.map(fn {key, value} -> [key, value] end)
    :crypto.hash(:sha256, JSON.encode!(canonical)) |> Base.encode16(case: :lower)
  end

  defp update_approvals(fun) do
    with {:ok, approvals} <- approvals(),
         {:ok, path} <- approvals_path() do
      persist_json(path, %{"version" => 1, "approvals" => fun.(approvals)}, :private)
    end
  end

  defp decode_approvals(data) do
    with {:ok, %{"version" => 1, "approvals" => approvals} = envelope} when is_map(approvals) <-
           JSON.decode(data),
         true <- Enum.sort(Map.keys(envelope)) == ["approvals", "version"],
         true <-
           Enum.all?(approvals, fn {path, servers} ->
             is_binary(path) and is_map(servers) and
               Enum.all?(servers, fn {name, hash} -> is_binary(name) and is_binary(hash) end)
           end) do
      {:ok, approvals}
    else
      _ -> {:error, :invalid_mcp_approvals}
    end
  end

  defp decode(data) do
    with {:ok, %{"version" => 1, "servers" => servers} = envelope} when is_map(servers) <-
           JSON.decode(data),
         true <- Enum.sort(Map.keys(envelope)) == ["servers", "version"],
         true <-
           Enum.all?(servers, fn {name, definition} ->
             valid_name(name) == :ok and valid_definition(definition) == :ok
           end) do
      {:ok, servers}
    else
      _ -> {:error, :invalid_mcp_config}
    end
  end

  defp valid_name(name) when is_binary(name) do
    if Regex.match?(@name, name), do: :ok, else: {:error, :invalid_mcp_name}
  end

  defp valid_name(_), do: {:error, :invalid_mcp_name}

  defp valid_definition(
         %{"transport" => "stdio", "command" => command, "args" => args} = definition
       )
       when is_binary(command) and command != "" and is_list(args) do
    if Enum.sort(Map.keys(definition)) == ["args", "command", "transport"] and
         Enum.all?(args, &is_binary/1) and Enum.all?([command | args], &printable?/1),
       do: :ok,
       else: {:error, :invalid_mcp_definition}
  end

  defp valid_definition(%{"transport" => "http", "url" => url} = definition)
       when is_binary(url) do
    uri = URI.parse(url)

    if Enum.sort(Map.keys(definition)) == ["transport", "url"] and printable?(url) and
         uri.scheme in ["https", "http"] and is_binary(uri.host) and
         (uri.scheme == "https" or uri.host in ["localhost", "127.0.0.1", "::1"]) and
         is_nil(uri.userinfo) and is_nil(uri.fragment) and is_nil(uri.query),
       do: :ok,
       else: {:error, :invalid_mcp_definition}
  end

  defp valid_definition(_), do: {:error, :invalid_mcp_definition}

  # Definitions are shown to the user for approval; control characters could
  # hide part of a command in the terminal.
  defp printable?(value),
    do: String.valid?(value) and not Regex.match?(~r/[\x00-\x1f\x7f]/, value)

  defp persist(path, servers, visibility),
    do: persist_json(path, %{"version" => 1, "servers" => servers}, visibility)

  # `:private` files live in `$TACKLE_HOME` (directory 0700, file 0600);
  # `:shared` project files keep the repository's directory permissions.
  defp persist_json(path, data, visibility) do
    dir = Path.dirname(path)

    with :ok <- if(visibility == :shared, do: safe_dir(dir), else: :ok),
         :ok <- File.mkdir_p(dir),
         :ok <- if(visibility == :private, do: File.chmod(dir, 0o700), else: :ok),
         :ok <- safe_target(path) do
      temp = path <> ".#{System.unique_integer([:positive])}.tmp"
      mode = if visibility == :private, do: 0o600, else: 0o644

      result =
        with :ok <- File.write(temp, JSON.encode!(data)),
             :ok <- File.chmod(temp, mode),
             :ok <- File.rename(temp, path),
             do: :ok

      File.rm(temp)
      result
    end
  end

  # A committed `.tackle` symlink must not redirect project writes elsewhere.
  defp safe_dir(dir) do
    case File.lstat(dir) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, _} -> {:error, :unsafe_mcp_config}
      error -> error
    end
  end

  defp safe_target(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, _} -> {:error, :unsafe_mcp_config}
      error -> error
    end
  end
end
