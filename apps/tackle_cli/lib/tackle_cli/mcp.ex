defmodule Tackle.CLI.MCP do
  @moduledoc false

  alias Tackle.CLI.MCP.Config
  alias Tackle.Plugins.MCP.OAuth

  def list do
    with {:ok, servers} <- Config.list() do
      Enum.each(Enum.sort(servers), fn {name, definition} ->
        Owl.IO.puts(
          "#{name}\t#{definition["transport"]}\t#{definition["url"] || definition["command"]}"
        )
      end)

      0
    else
      error -> fail(error)
    end
  end

  def add(%{name: name, stdio: command, http: url, args: args}) do
    definition =
      cond do
        is_binary(command) and is_nil(url) ->
          %{"transport" => "stdio", "command" => command, "args" => args}

        is_binary(url) and is_nil(command) and args == [] ->
          %{"transport" => "http", "url" => url}

        true ->
          nil
      end

    case Config.put(name, definition) do
      :ok ->
        Owl.IO.puts("Added MCP server #{name}")
        0

      error ->
        fail(error)
    end
  end

  def remove(name) do
    with {:ok, _} <- Application.ensure_all_started(:tackle_cli),
         {:ok, servers} <- Config.list(),
         {:ok, _definition} <- fetch_server(servers, name),
         :ok <- Tackle.Auth.delete(namespace(name)),
         :ok <- Config.remove(name),
         :ok <- Tackle.CLI.MCP.Connections.invalidate(name) do
      Owl.IO.puts("Removed MCP server #{name}")
      0
    else
      error -> fail(error)
    end
  end

  def status(name) do
    with {:ok, _} <- Application.ensure_all_started(:tackle_cli),
         {:ok, servers} <- Config.list() do
      servers = if name, do: Map.take(servers, [name]), else: servers

      if name && servers == %{},
        do: fail({:error, :mcp_server_missing}),
        else: print_status(servers)
    else
      error -> fail(error)
    end
  end

  defp print_status(servers) do
    Enum.each(Enum.sort(servers), fn {name, definition} ->
      status =
        if definition["transport"] == "stdio" do
          "not applicable"
        else
          case Tackle.Auth.status(namespace(name)) do
            :stored -> "stored"
            :missing -> "missing"
            {:error, reason} -> "error: #{inspect(reason)}"
          end
        end

      Owl.IO.puts("#{name}\t#{status}")
    end)

    0
  end

  def logout(name) do
    with {:ok, _} <- Application.ensure_all_started(:tackle_cli),
         {:ok, servers} <- Config.list(),
         {:ok, _} <- fetch_server(servers, name),
         :ok <- Tackle.Auth.delete(namespace(name)),
         :ok <- Tackle.CLI.MCP.Connections.invalidate(name) do
      Owl.IO.puts("Removed MCP credentials for #{name}")
      0
    else
      error -> fail(error)
    end
  end

  def login(%{name: name, client_id: client_id}) do
    with {:ok, _} <- Application.ensure_all_started(:tackle_cli),
         {:ok, servers} <- Config.list(),
         {:ok, %{"transport" => "http", "url" => url}} <- fetch_server(servers, name),
         {:ok, listener} <-
           :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true]),
         result <- authorize(name, url, listener, client_id) do
      result
    else
      {:ok, _} -> fail({:error, :mcp_oauth_requires_http})
      error -> fail(error)
    end
  end

  defp authorize(name, url, listener, client_id) do
    try do
      {:ok, {_ip, port}} = :inet.sockname(listener)
      redirect = "http://127.0.0.1:#{port}/callback"

      with {:ok, flow} <-
             OAuth.begin(url,
               redirect_uri: redirect,
               finch_name: Tackle.CLI.MCP.Finch,
               client_id: client_id
             ),
           :ok <- announce(flow.authorization_url),
           {:ok, state, code, socket} <- callback(listener, flow.state),
           result <- OAuth.complete(flow, state, code: code),
           :ok <- respond(socket, result),
           {:ok, credentials} <- result,
           :ok <- Tackle.Auth.put(namespace(name), persistable(credentials)) do
        Owl.IO.puts("Authorized MCP server #{name}")
        0
      else
        error -> fail(error)
      end
    after
      :gen_tcp.close(listener)
    end
  end

  defp announce(url) do
    Owl.IO.puts(
      "Open this URL to authorize the MCP server:\n#{url}\nWaiting for browser callback (up to 2 minutes)..."
    )

    :ok
  end

  defp callback(listener, expected) do
    deadline = System.monotonic_time(:millisecond) + 120_000
    wait_callback(listener, expected, deadline)
  end

  defp wait_callback(listener, expected, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :oauth_callback_timeout}
    else
      case :gen_tcp.accept(listener, remaining) do
        {:ok, socket} ->
          case :gen_tcp.recv(socket, 0, min(5_000, remaining)) do
            {:ok, line} ->
              case Regex.run(~r/\AGET \/callback\?([^ ]+) HTTP\/1\.[01]\r\n/, line) do
                [_, query] ->
                  params = URI.decode_query(query)

                  case params do
                    %{"state" => ^expected, "code" => code} when code != "" ->
                      {:ok, expected, code, socket}

                    _ ->
                      respond(socket, {:error, :invalid_oauth_callback})
                      wait_callback(listener, expected, deadline)
                  end

                _ ->
                  respond(socket, {:error, :invalid_oauth_callback})
                  wait_callback(listener, expected, deadline)
              end

            _ ->
              :gen_tcp.close(socket)
              wait_callback(listener, expected, deadline)
          end

        error ->
          error
      end
    end
  end

  defp respond(socket, result) do
    {status, body} =
      case result do
        {:ok, _} -> {"200 OK", "Authorization complete. Return to your terminal."}
        _ -> {"400 Bad Request", "Authorization failed. Return to your terminal."}
      end

    :gen_tcp.send(
      socket,
      "HTTP/1.1 #{status}\r\nContent-Type: text/plain\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"
    )

    :gen_tcp.close(socket)
    :ok
  end

  defp persistable(credentials) do
    credentials |> Map.drop([:request]) |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp fetch_server(servers, name) do
    case Map.fetch(servers, name) do
      {:ok, definition} -> {:ok, definition}
      :error -> {:error, :mcp_server_missing}
    end
  end

  def namespace(name), do: "mcp:#{name}"

  defp fail(reason) do
    Owl.IO.puts("MCP error: #{inspect(reason)}", :stderr)
    1
  end
end
