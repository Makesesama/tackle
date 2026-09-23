defmodule Tackle.CLI.MCP.Config do
  @moduledoc false

  @name ~r/\A[A-Za-z0-9_-]{1,32}\z/

  def path do
    with {:ok, home} <- Tackle.Paths.home(), do: {:ok, Path.join(home, "mcp.json")}
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
         false <- Map.has_key?(servers, name) do
      persist(Map.put(servers, name, definition))
    else
      true -> {:error, :mcp_server_exists}
      error -> error
    end
  end

  def remove(name) do
    with :ok <- valid_name(name), {:ok, servers} <- list(), true <- Map.has_key?(servers, name) do
      persist(Map.delete(servers, name))
    else
      false -> {:error, :mcp_server_missing}
      error -> error
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
         Enum.all?(args, &is_binary/1), do: :ok, else: {:error, :invalid_mcp_definition}
  end

  defp valid_definition(%{"transport" => "http", "url" => url} = definition)
       when is_binary(url) do
    uri = URI.parse(url)

    if Enum.sort(Map.keys(definition)) == ["transport", "url"] and
         uri.scheme in ["https", "http"] and is_binary(uri.host) and
         (uri.scheme == "https" or uri.host in ["localhost", "127.0.0.1", "::1"]) and
         is_nil(uri.userinfo) and is_nil(uri.fragment) and is_nil(uri.query),
       do: :ok,
       else: {:error, :invalid_mcp_definition}
  end

  defp valid_definition(_), do: {:error, :invalid_mcp_definition}

  defp persist(servers) do
    with {:ok, path} <- path(),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.chmod(Path.dirname(path), 0o700),
         :ok <- safe_target(path) do
      temp = path <> ".#{System.unique_integer([:positive])}.tmp"

      result =
        with :ok <- File.write(temp, JSON.encode!(%{"version" => 1, "servers" => servers})),
             :ok <- File.chmod(temp, 0o600),
             :ok <- File.rename(temp, path),
             do: :ok

      File.rm(temp)
      result
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
