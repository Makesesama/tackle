defmodule Tackle.Plugins.MCP do
  @moduledoc """
  MCP client plugin that discovers remote tools through Anubis and exposes them
  as `Tackle.Lib.Tool` modules.

  One client process is started per configured server. Call `connect/1` during
  trusted host startup, add the returned tool modules to the session's `:tools`,
  and call `disconnect/1` when the host no longer needs the connection.

  This first version bridges MCP tools over STDIO and Streamable HTTP. Resources,
  prompts, dynamic tool-list updates, and automatic Streamable HTTP session
  recovery are intentionally out of scope.
  """

  alias Tackle.Plugins.MCP.{Connection, Tool}

  @default_timeout 30_000
  @default_call_timeout 60_000
  @server_name_pattern ~r/\A[A-Za-z0-9_-]{1,32}\z/

  @type connection :: %{
          required(:server_name) => String.t(),
          required(:client) => GenServer.server(),
          required(:supervisor) => pid(),
          required(:tools) => [module()]
        }

  @doc "Starts one MCP connection, discovers all of its tools, and builds Tackle proxies."
  @spec connect(keyword()) :: {:ok, connection()} | {:error, term()}
  def connect(opts) when is_list(opts) do
    with :ok <- validate_server_name(opts[:server_name]),
         {:ok, transport} <- transport(opts),
         {:ok, connection} <- connection_module(opts),
         :ok <- validate_timeouts(opts),
         {:ok, client_name, transport_name} <- process_names(opts[:server_name]),
         client_opts <- client_options(opts, transport, client_name, transport_name),
         {:ok, supervisor} <- start_connection(opts[:server_name], client_opts, connection) do
      finish_connect(supervisor, client_name, connection, opts)
    end
  rescue
    exception -> {:error, {:invalid_mcp_configuration, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:mcp_connection_exit, reason}}
  end

  def connect(opts), do: {:error, {:invalid_mcp_options, opts}}

  @doc "Stops a connection returned by `connect/1`."
  @spec disconnect(connection()) :: :ok | {:error, term()}
  def disconnect(%{supervisor: supervisor}) when is_pid(supervisor) do
    stop_connection(supervisor)
  end

  @doc "Returns the proxy tool modules discovered for a connection."
  @spec tools(connection()) :: [module()]
  def tools(%{tools: tools}), do: tools

  @doc "Updates the bearer header on an existing HTTP connection after token refresh."
  @spec update_http_token(connection(), String.t()) :: :ok | {:error, term()}
  def update_http_token(%{server_name: server_name, supervisor: supervisor}, token)
      when is_binary(token) and token != "" do
    if Process.alive?(supervisor) do
      transport =
        {:via, Registry, {Tackle.Plugins.MCP.Registry, {{:mcp_server, server_name}, :transport}}}

      try do
        :sys.replace_state(transport, fn state ->
          %{state | headers: Map.put(state.headers, "authorization", "Bearer " <> token)}
        end)

        :ok
      catch
        :exit, reason -> {:error, {:http_transport_unavailable, reason}}
      end
    else
      {:error, :http_transport_unavailable}
    end
  end

  def update_http_token(_, _), do: {:error, :invalid_http_token}

  defp finish_connect(supervisor, client_name, connection, opts) do
    monitor = Process.monitor(supervisor)

    try do
      with :ok <- await_ready(connection, client_name, opts),
           {:ok, tools} <- discover_tools(opts[:server_name], client_name, connection, opts) do
        {:ok,
         %{
           server_name: opts[:server_name],
           client: client_name,
           supervisor: supervisor,
           tools: tools
         }}
      else
        {:error, reason} ->
          stop_connection(supervisor)
          {:error, reason}
      end
    rescue
      exception ->
        stop_connection(supervisor)
        {:error, {:invalid_mcp_configuration, Exception.message(exception)}}
    catch
      :exit, reason ->
        stop_connection(supervisor)
        {:error, {:mcp_connection_exit, reason}}
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp stop_connection(supervisor) do
    monitor = Process.monitor(supervisor)
    terminate_and_wait(supervisor, monitor)
  end

  defp terminate_and_wait(supervisor, monitor) do
    result =
      case DynamicSupervisor.terminate_child(Tackle.Plugins.MCP.Supervisor, supervisor) do
        :ok -> :ok
        {:error, :not_found} -> :ok
        {:error, reason} -> {:error, reason}
      end

    receive do
      {:DOWN, ^monitor, :process, ^supervisor, _reason} -> result
    after
      5_000 ->
        Process.demonitor(monitor, [:flush])
        result
    end
  catch
    :exit, _reason ->
      Process.demonitor(monitor, [:flush])
      :ok
  end

  defp start_connection(server_name, client_opts, connection) do
    spec = {connection, server_name: server_name, client_opts: client_opts}

    case DynamicSupervisor.start_child(Tackle.Plugins.MCP.Supervisor, spec) do
      {:ok, supervisor} ->
        {:ok, supervisor}

      {:error, {:already_started, supervisor}} ->
        {:error, {:server_already_connected, server_name, supervisor}}

      {:error, reason} ->
        {:error, {:connection_start_failed, server_name, reason}}
    end
  end

  defp await_ready(connection, client, opts) do
    timeout = Keyword.get(opts, :connect_timeout, @default_timeout)

    case connection.await_ready(client, timeout) do
      :ok -> :ok
      {:error, reason} -> {:error, {:initialization_failed, reason}}
      other -> {:error, {:unexpected_initialization_response, other}}
    end
  catch
    :exit, reason -> {:error, {:initialization_failed, reason}}
  end

  defp discover_tools(server_name, client, connection, opts) do
    timeout = Keyword.get(opts, :discovery_timeout, @default_timeout)
    call_timeout = Keyword.get(opts, :tool_call_timeout, @default_call_timeout)

    with {:ok, descriptors} <- list_all_tools(client, connection, timeout),
         {:ok, tools, _names} <-
           create_tools(descriptors, server_name, client, connection, call_timeout) do
      {:ok, Enum.reverse(tools)}
    end
  end

  defp create_tools(descriptors, server_name, client, connection, call_timeout) do
    Enum.reduce_while(descriptors, {:ok, [], MapSet.new()}, fn descriptor, acc ->
      create_tool(descriptor, acc, server_name, client, connection, call_timeout)
    end)
  end

  defp create_tool(descriptor, {:ok, tools, names}, server_name, client, connection, timeout) do
    case Tool.create(server_name, descriptor, client, connection, timeout) do
      {:ok, tool} -> add_unique_tool(tool, tools, names)
      {:error, reason} -> {:halt, {:error, {:invalid_mcp_tool, descriptor["name"], reason}}}
    end
  end

  defp add_unique_tool(tool, tools, names) do
    name = tool.name()

    if MapSet.member?(names, name) do
      {:halt, {:error, {:duplicate_mcp_tool_name, name}}}
    else
      {:cont, {:ok, [tool | tools], MapSet.put(names, name)}}
    end
  end

  defp list_all_tools(client, connection, timeout) do
    list_tool_pages(client, connection, timeout, nil, MapSet.new(), [])
  end

  defp list_tool_pages(client, connection, timeout, cursor, seen_cursors, tools) do
    request_opts = if cursor, do: [cursor: cursor, timeout: timeout], else: [timeout: timeout]

    with {:ok, result} <- connection.list_tools(client, request_opts),
         {:ok, page_tools} <- fetch_page_tools(result),
         {:ok, next_cursor} <- fetch_next_cursor(result),
         :ok <- ensure_new_cursor(next_cursor, seen_cursors) do
      tools = tools ++ page_tools

      if next_cursor do
        list_tool_pages(
          client,
          connection,
          timeout,
          next_cursor,
          MapSet.put(seen_cursors, next_cursor),
          tools
        )
      else
        {:ok, tools}
      end
    end
  end

  defp fetch_page_tools(%{"tools" => tools}) when is_list(tools), do: {:ok, tools}
  defp fetch_page_tools(result), do: {:error, {:invalid_tools_list, result}}

  defp fetch_next_cursor(result) do
    case Map.get(result, "nextCursor") do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      cursor when is_binary(cursor) -> {:ok, cursor}
      cursor -> {:error, {:invalid_next_cursor, cursor}}
    end
  end

  defp ensure_new_cursor(nil, _seen), do: :ok

  defp ensure_new_cursor(cursor, seen) do
    if MapSet.member?(seen, cursor),
      do: {:error, {:repeated_next_cursor, cursor}},
      else: :ok
  end

  defp client_options(opts, transport, client_name, transport_name) do
    [
      name: client_name,
      transport_name: transport_name,
      transport: transport,
      client_info: %{
        "name" => "tackle-mcp-#{opts[:server_name]}",
        "version" => "0.1.0"
      },
      capabilities: %{}
    ]
  end

  defp process_names(server_name) do
    key = {:mcp_server, server_name}

    {:ok, {:via, Registry, {Tackle.Plugins.MCP.Registry, {key, :client}}},
     {:via, Registry, {Tackle.Plugins.MCP.Registry, {key, :transport}}}}
  end

  defp transport(opts) do
    case Keyword.fetch(opts, :transport) do
      {:ok, {:stdio, transport_opts}} when is_list(transport_opts) ->
        {:ok, {:stdio, transport_opts}}

      {:ok, {:streamable_http, transport_opts}} when is_list(transport_opts) ->
        finch_name = Keyword.get(transport_opts, :finch_name)

        if is_nil(finch_name) do
          {:error, {:missing_transport_option, :finch_name}}
        else
          {:ok, {:streamable_http, transport_opts}}
        end

      {:ok, transport} ->
        {:error, {:unsupported_transport, transport}}

      :error ->
        {:error, {:missing_mcp_option, :transport}}
    end
  end

  defp connection_module(opts) do
    case Keyword.get(opts, :connection, Connection) do
      module when is_atom(module) -> {:ok, module}
      value -> {:error, {:invalid_connection_module, value}}
    end
  end

  defp validate_server_name(server_name) do
    if is_binary(server_name) and Regex.match?(@server_name_pattern, server_name),
      do: :ok,
      else: {:error, {:invalid_server_name, server_name}}
  end

  defp validate_timeouts(opts) do
    [:connect_timeout, :discovery_timeout, :tool_call_timeout]
    |> Enum.reduce_while(:ok, fn key, :ok ->
      case Keyword.get(opts, key) do
        nil -> {:cont, :ok}
        timeout when is_integer(timeout) and timeout > 0 -> {:cont, :ok}
        timeout -> {:halt, {:error, {:invalid_timeout, key, timeout}}}
      end
    end)
  end
end
