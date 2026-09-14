defmodule Tackle.Plugins.MCPTest do
  use ExUnit.Case, async: false

  alias Tackle.Plugins.MCP

  defmodule FakeConnection do
    def child_spec(opts) do
      %{
        id: {:fake_mcp, Keyword.fetch!(opts, :server_name)},
        start: {Task, :start_link, [fn -> Process.sleep(:infinity) end]},
        restart: :permanent
      }
    end

    def await_ready(_client, _timeout), do: :ok

    def list_tools(_client, opts) do
      send(self(), {:listed, Keyword.get(opts, :cursor)})

      case Keyword.get(opts, :cursor) do
        nil ->
          {:ok,
           %{
             "tools" => [tool("first")],
             "nextCursor" => "page-2"
           }}

        "page-2" ->
          {:ok, %{"tools" => [tool("second")]}}
      end
    end

    def call_tool(_client, name, arguments, _opts) do
      {:ok, %{"content" => [%{"type" => "text", "text" => "#{name}:#{inspect(arguments)}"}]}}
    end

    defp tool(name) do
      %{
        "name" => name,
        "description" => "Tool #{name}",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      }
    end
  end

  defmodule RepeatingCursorConnection do
    defdelegate child_spec(opts), to: FakeConnection
    def await_ready(_client, _timeout), do: :ok

    def list_tools(_client, _opts) do
      {:ok, %{"tools" => [], "nextCursor" => "same"}}
    end
  end

  test "connects, drains tool pagination, and disconnects" do
    opts = [
      server_name: "demo",
      transport: {:stdio, command: "unused"},
      connection: FakeConnection
    ]

    assert {:ok, connection} = MCP.connect(opts)
    assert Enum.map(connection.tools, & &1.name()) == ["mcp__demo__first", "mcp__demo__second"]
    assert_received {:listed, nil}
    assert_received {:listed, "page-2"}

    [first | _] = connection.tools
    assert {:ok, result} = first.execute(%{}, %{})
    assert result =~ "first"

    assert :ok = MCP.disconnect(connection)
  end

  test "rejects repeated pagination cursors and cleans up the client" do
    opts = [
      server_name: "cycle",
      transport: {:stdio, command: "unused"},
      connection: RepeatingCursorConnection
    ]

    assert {:error, {:repeated_next_cursor, "same"}} = MCP.connect(opts)
  end

  test "requires callers to provide a supervised Finch pool for HTTP" do
    assert {:error, {:missing_transport_option, :finch_name}} =
             MCP.connect(
               server_name: "web",
               transport: {:streamable_http, base_url: "https://example.test"},
               connection: FakeConnection
             )
  end

  test "validates stable local server names and timeouts" do
    assert {:error, {:invalid_server_name, "not valid"}} =
             MCP.connect(
               server_name: "not valid",
               transport: {:stdio, command: "unused"},
               connection: FakeConnection
             )

    assert {:error, {:invalid_timeout, :tool_call_timeout, 0}} =
             MCP.connect(
               server_name: "demo",
               transport: {:stdio, command: "unused"},
               connection: FakeConnection,
               tool_call_timeout: 0
             )
  end
end
