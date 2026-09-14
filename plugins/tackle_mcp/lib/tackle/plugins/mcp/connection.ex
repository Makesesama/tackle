defmodule Tackle.Plugins.MCP.Connection do
  @moduledoc false

  alias Anubis.Client
  alias Anubis.MCP.{Error, Response}

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    client_opts = Keyword.fetch!(opts, :client_opts)

    %{
      id: {:mcp_connection, Keyword.fetch!(opts, :server_name)},
      start: {__MODULE__, :start_link, [client_opts]},
      restart: :permanent,
      type: :supervisor
    }
  end

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(client_opts), do: Client.start_link(client_opts)

  @spec await_ready(GenServer.server(), timeout()) :: :ok | {:error, term()}
  def await_ready(client, timeout) do
    Client.await_ready(client, timeout: timeout)
  catch
    :exit, reason -> {:error, {:client_exit, reason}}
  end

  @spec list_tools(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_tools(client, opts) do
    case Client.list_tools(client, opts) do
      {:ok, %Response{result: result}} when is_map(result) -> {:ok, result}
      {:error, %Error{} = error} -> {:error, error_details(error)}
      other -> {:error, {:unexpected_list_tools_response, other}}
    end
  catch
    :exit, reason -> {:error, {:client_exit, reason}}
  end

  @spec call_tool(GenServer.server(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def call_tool(client, name, arguments, opts) do
    case Client.call_tool(client, name, arguments, opts) do
      {:ok, %Response{result: result, is_error: true}} ->
        {:error, {:tool_error, result}}

      {:ok, %Response{result: result}} when is_map(result) ->
        {:ok, result}

      {:error, %Error{} = error} ->
        {:error, error_details(error)}

      other ->
        {:error, {:unexpected_call_tool_response, other}}
    end
  catch
    :exit, reason -> {:error, {:client_exit, reason}}
  end

  defp error_details(error) do
    {:mcp_error, error.reason, error.message}
  end
end
