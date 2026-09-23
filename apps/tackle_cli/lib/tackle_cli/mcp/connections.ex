defmodule Tackle.CLI.MCP.Connections do
  @moduledoc false
  use GenServer

  alias Tackle.CLI.MCP.Config
  alias Tackle.Plugins.MCP
  alias Tackle.Plugins.MCP.OAuth

  @refresh_interval :timer.seconds(30)
  @refresh_skew 90
  @retry_interval 15

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc "Connects configured servers once per CLI process and returns root-only tool modules."
  def tools, do: GenServer.call(__MODULE__, :tools, 120_000)

  @doc "Disconnects a server immediately after logout or removal."
  def invalidate(name), do: GenServer.call(__MODULE__, {:invalidate, name})

  @impl true
  def handle_call({:invalidate, name}, _from, state) do
    case Map.pop(state, name) do
      {nil, rest} -> {:reply, :ok, rest}
      {entry, rest} -> {:reply, MCP.disconnect(entry.connection), rest}
    end
  end

  @impl true
  def handle_call(:tools, _from, state) do
    case Config.list() do
      {:ok, definitions} ->
        case reconcile(Enum.sort(definitions), state) do
          {:ok, connections} ->
            tools =
              connections
              |> Map.values()
              |> Enum.flat_map(fn entry -> MCP.tools(entry.connection) end)

            {:reply, {:ok, tools}, connections}

          {:error, reason, connections} ->
            {:reply, {:error, reason}, connections}
        end

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def init(_) do
    schedule_refresh()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:refresh, state) do
    state =
      case Config.list() do
        {:ok, definitions} ->
          names = MapSet.new(definitions, fn {name, _} -> name end)

          Enum.reduce(state, state, fn {name, entry}, acc ->
            cond do
              not MapSet.member?(names, name) ->
                MCP.disconnect(entry.connection)
                Map.delete(acc, name)

              renewal_due?(entry) ->
                case refresh_connection(name, entry) do
                  {:ok, updated} ->
                    Map.put(acc, name, updated)

                  {:error, _} ->
                    Map.put(
                      acc,
                      name,
                      Map.put(entry, :retry_after, System.system_time(:second) + @retry_interval)
                    )
                end

              true ->
                acc
            end
          end)

        _ ->
          state
      end

    schedule_refresh()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state, fn {_name, entry} -> MCP.disconnect(entry.connection) end)
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_interval)

  defp reconcile(definitions, state) do
    names = MapSet.new(definitions, fn {name, _} -> name end)

    state =
      Enum.reduce(state, state, fn {name, entry}, current ->
        if MapSet.member?(names, name) do
          current
        else
          MCP.disconnect(entry.connection)
          Map.delete(current, name)
        end
      end)

    Enum.reduce_while(definitions, {:ok, state}, fn {name, definition}, {:ok, current} ->
      entry = Map.get(current, name)

      cond do
        entry && entry.definition == definition && Process.alive?(entry.connection.supervisor) &&
          is_integer(Map.get(entry, :retry_after)) &&
            Map.get(entry, :retry_after) > System.system_time(:second) ->
          {:halt, {:error, {:mcp_connection_failed, name, :mcp_token_refresh_pending}, current}}

        entry && entry.definition == definition && Process.alive?(entry.connection.supervisor) &&
            not renewal_due?(entry) ->
          {:cont, {:ok, current}}

        entry && entry.definition == definition && Process.alive?(entry.connection.supervisor) &&
            renewal_due?(entry) ->
          case refresh_connection(name, entry) do
            {:ok, updated} ->
              {:cont, {:ok, Map.put(current, name, updated)}}

            {:error, reason} ->
              failed = Map.put(entry, :retry_after, System.system_time(:second) + @retry_interval)

              {:halt,
               {:error, {:mcp_connection_failed, name, reason}, Map.put(current, name, failed)}}
          end

        entry ->
          case reconnect(name, %{entry | definition: definition}) do
            {:ok, updated} -> {:cont, {:ok, Map.put(current, name, updated)}}
            {:error, reason} -> {:halt, {:error, {:mcp_connection_failed, name, reason}, current}}
          end

        true ->
          case connect(name, definition) do
            {:ok, connected} -> {:cont, {:ok, Map.put(current, name, connected)}}
            {:error, reason} -> {:halt, {:error, {:mcp_connection_failed, name, reason}, current}}
          end
      end
    end)
  end

  defp renewal_due?(%{retry_after: retry_after}) when is_integer(retry_after),
    do: retry_after <= System.system_time(:second)

  defp renewal_due?(%{definition: %{"transport" => "http"}, expires_at: expires})
       when is_integer(expires),
       do: expires <= System.system_time(:second) + @refresh_skew

  defp renewal_due?(_), do: false

  defp refresh_connection(name, entry) do
    with {:ok, credentials} <- Tackle.Auth.fetch(Tackle.CLI.MCP.namespace(name)),
         :ok <- check_resource(credentials, entry.definition["url"]),
         {:ok, fresh} <- fresh_credentials(name, credentials),
         {:ok, token} <- access_token(fresh),
         :ok <- MCP.update_http_token(entry.connection, token) do
      {:ok, Map.merge(entry, %{expires_at: fresh["expires_at"], retry_after: nil})}
    else
      :error -> {:error, :mcp_auth_required}
      error -> error
    end
  end

  defp reconnect(name, entry) do
    # The generated proxy modules use stable registry names, so existing scopes
    # continue to address the reconnected client. A failed replacement is never
    # silently presented as a successful connection to a new session.
    with :ok <- MCP.disconnect(entry.connection) do
      connect(name, entry.definition)
    end
  end

  defp connect(name, %{"transport" => "stdio", "command" => command, "args" => args} = definition) do
    case MCP.connect(server_name: name, transport: {:stdio, command: command, args: args}) do
      {:ok, connection} ->
        {:ok, %{connection: connection, definition: definition, expires_at: nil}}

      error ->
        error
    end
  end

  defp connect(name, %{"transport" => "http", "url" => url} = definition) do
    with {:ok, credentials} <- Tackle.Auth.fetch(Tackle.CLI.MCP.namespace(name)),
         :ok <- check_resource(credentials, url),
         {:ok, credentials} <- fresh_credentials(name, credentials),
         {:ok, token} <- access_token(credentials),
         uri <- URI.parse(url),
         {:ok, connection} <-
           MCP.connect(
             server_name: name,
             transport:
               {:streamable_http,
                base_url: "#{uri.scheme}://#{uri.authority}",
                mcp_path: uri.path || "/mcp",
                headers: %{"authorization" => "Bearer #{token}"},
                finch_name: Tackle.CLI.MCP.Finch}
           ) do
      {:ok,
       %{connection: connection, definition: definition, expires_at: credentials["expires_at"]}}
    else
      :error -> {:error, :mcp_auth_required}
      error -> error
    end
  end

  defp check_resource(%{"resource" => url}, url), do: :ok
  defp check_resource(_, _), do: {:error, :mcp_credentials_for_different_resource}

  defp access_token(%{"access_token" => token}) when is_binary(token) and token != "",
    do: {:ok, token}

  defp access_token(_), do: {:error, :mcp_auth_required}

  defp fresh_credentials(name, %{"expires_at" => expires} = credentials)
       when is_integer(expires) do
    if expires <= System.system_time(:second) + @refresh_skew do
      with {:ok, fresh} <-
             OAuth.refresh_stored(credentials, finch_name: Tackle.CLI.MCP.Finch),
           :ok <- Tackle.Auth.put(Tackle.CLI.MCP.namespace(name), fresh) do
        {:ok, fresh}
      end
    else
      {:ok, credentials}
    end
  end

  defp fresh_credentials(_name, credentials), do: {:ok, credentials}
end
