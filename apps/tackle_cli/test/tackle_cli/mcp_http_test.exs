defmodule Tackle.CLI.MCPHTTPTest do
  use ExUnit.Case, async: false

  alias Tackle.CLI.MCP.Config
  alias Tackle.CLI.MCP.Connections
  alias Tackle.FileLock

  setup do
    home = Path.join(System.tmp_dir!(), "tackle-mcp-http-#{System.unique_integer([:positive])}")
    previous = System.get_env("TACKLE_HOME")
    System.put_env("TACKLE_HOME", home)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()
    server = spawn_link(fn -> accept(listener, parent) end)
    url = "http://127.0.0.1:#{port}/mcp"
    name = "test#{System.unique_integer([:positive])}"
    :ok = Config.put(name, %{"transport" => "http", "url" => url})

    credentials = %{
      "resource" => url,
      "access_token" => "initial",
      "expires_at" => System.system_time(:second) + 300
    }

    :ok = Tackle.Auth.put("mcp:#{name}", credentials)

    on_exit(fn ->
      Connections.invalidate(name)
      :gen_tcp.close(listener)
      Process.exit(server, :kill)

      if previous,
        do: System.put_env("TACKLE_HOME", previous),
        else: System.delete_env("TACKLE_HOME")

      File.rm_rf!(home)
    end)

    {:ok, name: name, url: url}
  end

  test "uses resource-bound OAuth bearer credentials to discover and invoke HTTP tools", %{
    name: name
  } do
    assert {:ok, tools} = Connections.tools()
    assert [tool] = Enum.filter(tools, &(&1.name() == "mcp__#{name}__echo"))
    assert {:ok, "hello"} = tool.execute(%{"value" => "hello"}, %{})
    assert_receive {:mcp_request, "initial", "tools/call"}
  end

  test "rejects credentials for a different resource", %{name: name} do
    :ok =
      Tackle.Auth.put("mcp:#{name}", %{
        "resource" => "https://other.example/mcp",
        "access_token" => "bad"
      })

    assert {:ok, []} = Connections.tools()

    refute_receive {:mcp_request, _, _}
  end

  test "logout invalidates an active connection", %{name: name} do
    assert {:ok, [_ | _]} = Connections.tools()
    :ok = Tackle.Auth.delete("mcp:#{name}")
    assert :ok = Connections.invalidate(name)
    assert {:ok, []} = Connections.tools()
  end

  test "removes a connection when its definition disappears", %{name: name} do
    assert {:ok, [_ | _]} = Connections.tools()
    assert :ok = Config.remove(name)
    assert {:ok, []} = Connections.tools()
    assert :ok = Connections.invalidate(name)
  end

  test "refresh failure leaves the existing transport running and reports the error", %{
    name: name,
    url: url
  } do
    assert {:ok, tools} = Connections.tools()
    [tool] = Enum.filter(tools, &(&1.name() == "mcp__#{name}__echo"))

    :ok =
      Tackle.Auth.put("mcp:#{name}", %{
        "resource" => url,
        "access_token" => "initial",
        "expires_at" => System.system_time(:second) + 1
      })

    :sys.replace_state(Connections, fn state ->
      update_in(state, [:servers, name, :expires_at], fn _ -> System.system_time(:second) + 1 end)
    end)

    assert {:ok, []} = Connections.tools()
    assert {:ok, "still-running"} = tool.execute(%{"value" => "still-running"}, %{})
    assert_receive {:mcp_request, "initial", "tools/call"}
  end

  test "a failed server does not hide healthy tools and can connect on a later run", %{
    name: name,
    url: url
  } do
    failed = "aaa#{System.unique_integer([:positive])}"
    on_exit(fn -> Connections.invalidate(failed) end)
    :ok = Config.put(failed, %{"transport" => "http", "url" => url})

    assert {:ok, tools} = Connections.tools()
    assert Enum.any?(tools, &(&1.name() == "mcp__#{name}__echo"))
    refute Enum.any?(tools, &(&1.name() == "mcp__#{failed}__echo"))

    :ok = Tackle.Auth.put("mcp:#{failed}", %{"resource" => url, "access_token" => "initial"})

    assert {:ok, tools} = Connections.tools()
    assert Enum.any?(tools, &(&1.name() == "mcp__#{failed}__echo"))
  end

  test "refreshes the bearer token for tools held by an existing session", %{name: name, url: url} do
    assert {:ok, tools} = Connections.tools()
    [tool] = Enum.filter(tools, &(&1.name() == "mcp__#{name}__echo"))
    endpoint = String.replace(url, "/mcp", "/token")

    :ok =
      Tackle.Auth.put("mcp:#{name}", %{
        "resource" => url,
        "access_token" => "initial",
        "refresh_token" => "refresh",
        "token_endpoint" => endpoint,
        "client_id" => "client",
        "expires_at" => System.system_time(:second) + 1
      })

    :sys.replace_state(Connections, fn state ->
      update_in(state, [:servers, name, :expires_at], fn _ -> System.system_time(:second) + 1 end)
    end)

    # The refresh has finished, transport included, once the server answers.
    send(Connections, :refresh)
    _state = :sys.get_state(Connections)
    assert {:ok, %{"access_token" => "renewed"}} = Tackle.Auth.fetch("mcp:#{name}")

    assert {:ok, "updated"} = tool.execute(%{"value" => "updated"}, %{})
    assert_receive {:mcp_request, "renewed", "tools/call"}
  end

  test "uses the credentials another process refreshed while it waited for the lock", %{
    name: name,
    url: url
  } do
    assert {:ok, tools} = Connections.tools()
    [tool] = Enum.filter(tools, &(&1.name() == "mcp__#{name}__echo"))
    namespace = "mcp:#{name}"

    stored = %{
      "resource" => url,
      "access_token" => "initial",
      "refresh_token" => "refresh",
      "token_endpoint" => String.replace(url, "/mcp", "/token"),
      "client_id" => "client",
      "expires_at" => System.system_time(:second) + 1
    }

    :ok = Tackle.Auth.put(namespace, stored)

    :sys.replace_state(Connections, fn state ->
      update_in(state, [:servers, name, :expires_at], fn _ -> System.system_time(:second) + 1 end)
    end)

    # This test stands for another process (another CLI, or `tackle sdk`)
    # that holds the lock while it refreshes and stores rotated credentials.
    waited =
      Tackle.Auth.with_lock(namespace, fn ->
        send(Connections, :refresh)
        waited = await_lock_or_refresh()

        :ok =
          Tackle.Auth.put(namespace, %{
            stored
            | "access_token" => "elsewhere",
              "refresh_token" => "rotated-elsewhere",
              "expires_at" => System.system_time(:second) + 3_600
          })

        waited
      end)

    assert waited == :waiting_for_lock
    _state = :sys.get_state(Connections)
    refute_received {:refresh_request, _body}
    assert {:ok, %{"refresh_token" => "rotated-elsewhere"}} = Tackle.Auth.fetch(namespace)
    assert {:ok, "updated"} = tool.execute(%{"value" => "updated"}, %{})
    assert_receive {:mcp_request, "elsewhere", "tools/call"}
  end

  test "connects project servers only after their exact definition is approved", %{url: url} do
    project =
      Path.join(System.tmp_dir!(), "tackle-mcp-project-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(project) end)
    File.mkdir_p!(Path.join(project, ".git"))
    File.mkdir_p!(Path.join(project, ".tackle"))
    name = "proj#{System.unique_integer([:positive])}"
    on_exit(fn -> Connections.invalidate(name) end)
    mcp_json = Path.join(project, ".tackle/mcp.json")
    definition = %{"transport" => "http", "url" => url}

    File.write!(
      mcp_json,
      JSON.encode!(%{"version" => 1, "servers" => %{name => definition}})
    )

    :ok = Tackle.Auth.put("mcp:#{name}", %{"resource" => url, "access_token" => "initial"})
    project_tool? = fn tools -> Enum.any?(tools, &(&1.name() == "mcp__#{name}__echo")) end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, tools} = Connections.tools(cwd: Path.join(project, "sub"))
        refute project_tool?.(tools)
      end)

    assert log =~ "tackle mcp approve #{name}"

    :ok = Config.approve(mcp_json, name, definition)
    assert {:ok, tools} = Connections.tools(cwd: project)
    assert project_tool?.(tools)

    # Any edit to the committed definition needs a fresh approval.
    File.write!(
      mcp_json,
      JSON.encode!(%{
        "version" => 1,
        "servers" => %{name => %{"transport" => "http", "url" => url <> "/other"}}
      })
    )

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:ok, tools} = Connections.tools(cwd: project)
      refute project_tool?.(tools)
    end)
  end

  test "an invalid project file does not hide user servers", %{name: name} do
    project =
      Path.join(System.tmp_dir!(), "tackle-mcp-project-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(project) end)
    File.mkdir_p!(Path.join(project, ".tackle"))
    File.write!(Path.join(project, ".tackle/mcp.json"), "not json")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, tools} = Connections.tools(cwd: project)
        assert Enum.any?(tools, &(&1.name() == "mcp__#{name}__echo"))
      end)

    assert log =~ "Ignoring project MCP servers"
  end

  # Waits until the connection refresh either waits for the namespace lock or
  # spends the refresh token.
  defp await_lock_or_refresh(retries \\ 200) do
    receive do
      {:refresh_request, _body} -> :refreshed
    after
      0 -> await_lock_or_refresh(retries, waiting_for_lock?(Connections))
    end
  end

  defp await_lock_or_refresh(_retries, true), do: :waiting_for_lock
  defp await_lock_or_refresh(0, false), do: :neither

  defp await_lock_or_refresh(retries, false) do
    Process.sleep(10)
    await_lock_or_refresh(retries - 1)
  end

  defp waiting_for_lock?(server) do
    {:current_stacktrace, frames} = Process.info(Process.whereis(server), :current_stacktrace)
    Enum.any?(frames, &match?({FileLock, _function, _arity, _location}, &1))
  end

  defp accept(listener, parent) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        handle_socket(socket, parent)
        accept(listener, parent)

      _ ->
        :ok
    end
  end

  defp handle_socket(socket, parent) do
    with {:ok, raw} <- :gen_tcp.recv(socket, 0, 5_000) do
      [head, fragment] = String.split(raw, "\r\n\r\n", parts: 2)

      length =
        case Regex.run(~r/content-length: (\d+)/i, head) do
          [_, n] -> String.to_integer(n)
          _ -> 0
        end

      body = read_body(socket, fragment, length)

      if String.starts_with?(head, "POST /token ") do
        send(parent, {:refresh_request, URI.decode_query(body)})

        response =
          JSON.encode!(%{
            "access_token" => "renewed",
            "refresh_token" => "rotated",
            "expires_in" => 300
          })

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(response)}\r\nConnection: close\r\n\r\n#{response}"
        )

        :gen_tcp.close(socket)
      else
        handle_mcp(socket, parent, head, body)
      end
    end
  end

  defp handle_mcp(socket, parent, head, body) do
    token =
      case Regex.run(~r/authorization: Bearer ([^\r\n]+)/i, head) do
        [_, value] -> value
        _ -> nil
      end

    message =
      case JSON.decode(body) do
        {:ok, data} -> data
        _ -> %{}
      end

    method = message["method"]
    send(parent, {:mcp_request, token, method})

    payload =
      case method do
        "initialize" ->
          %{
            "protocolVersion" => "2025-06-18",
            "capabilities" => %{"tools" => %{}},
            "serverInfo" => %{"name" => "test", "version" => "1"}
          }

        "tools/list" ->
          %{
            "tools" => [
              %{"name" => "echo", "inputSchema" => %{"type" => "object", "properties" => %{}}}
            ]
          }

        "tools/call" ->
          %{
            "content" => [
              %{"type" => "text", "text" => message["params"]["arguments"]["value"]}
            ]
          }

        _ ->
          nil
      end

    if payload do
      response = JSON.encode!(%{"jsonrpc" => "2.0", "id" => message["id"], "result" => payload})

      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(response)}\r\nConnection: close\r\n\r\n#{response}"
      )
    else
      :gen_tcp.send(
        socket,
        "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      )
    end

    :gen_tcp.close(socket)
  end

  defp read_body(_socket, body, length) when byte_size(body) >= length, do: body

  defp read_body(socket, body, length) do
    {:ok, more} = :gen_tcp.recv(socket, length - byte_size(body), 5_000)
    body <> more
  end
end
