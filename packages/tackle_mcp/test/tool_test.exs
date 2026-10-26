defmodule Tackle.Plugins.MCP.ToolTest do
  use ExUnit.Case, async: false

  alias Tackle.Lib.Tool, as: LibTool
  alias Tackle.Lib.Tool.Call
  alias Tackle.Lib.Tool.Content
  alias Tackle.Lib.Tool.Error, as: ToolError
  alias Tackle.Plugins.MCP.Tool

  defmodule FakeConnection do
    def call_tool(_client, "structured", arguments, _opts) do
      send(self(), {:called, "structured", arguments})
      {:ok, %{"structuredContent" => %{"answer" => 42}, "content" => []}}
    end

    def call_tool(_client, "mixed", _arguments, _opts) do
      {:ok,
       %{
         "content" => [
           %{"type" => "text", "text" => "hello"},
           %{"type" => "image", "mimeType" => "image/png", "data" => "YWJj"}
         ]
       }}
    end

    def call_tool(_client, "failure", _arguments, _opts) do
      {:error, {:tool_error, %{"content" => [%{"type" => "text", "text" => "bad"}]}}}
    end

    def call_tool(_client, "rpc_failure", _arguments, _opts) do
      {:error, {:mcp_error, :invalid_params, "Invalid params: value"}}
    end

    def call_tool(_client, "silent_rpc_failure", _arguments, _opts) do
      {:error, {:mcp_error, %{"internal" => "secret-token"}, nil}}
    end

    def call_tool(_client, "client_exit", _arguments, _opts) do
      {:error, {:client_exit, {:noproc, "secret-token"}}}
    end
  end

  test "creates a namespaced Tackle tool and preserves the raw wire name" do
    descriptor = %{
      "name" => "structured",
      "description" => "Returns data",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"value" => %{"type" => "integer"}},
        "required" => ["value"]
      },
      "outputSchema" => %{"type" => "object"}
    }

    assert {:ok, tool} = Tool.create("demo", descriptor, self(), FakeConnection, 123)
    assert tool.name() == "mcp__demo__structured"
    assert tool.description() == "Returns data"
    assert tool.parameters_schema() == [value: [type: :integer, required: true]]
    assert tool.output_schema() == %{"type" => "object"}

    assert {:ok, %{"answer" => 42}} = tool.execute(%{"value" => 3}, %{})
    assert_received {:called, "structured", %{"value" => 3}}
  end

  test "projects MCP text and image content" do
    descriptor = %{"name" => "mixed", "inputSchema" => %{}}

    assert {:ok, tool} = Tool.create("demo", descriptor, self(), FakeConnection, 123)

    assert {:ok,
            %Content{
              text: "hello",
              parts: [%{"type" => "image", "media_type" => "image/png", "data" => "YWJj"}]
            }} = tool.execute(%{}, %{})
  end

  test "maps MCP tool failures to Tackle execution errors" do
    descriptor = %{"name" => "failure", "inputSchema" => %{}}

    assert {:ok, tool} = Tool.create("demo", descriptor, self(), FakeConnection, 123)
    assert {:error, message} = tool.execute(%{}, %{})
    assert message =~ "MCP tool call failed"
  end

  test "shows MCP error text to the model and hides other failure reasons" do
    for {raw_name, content} <- [
          {"failure", "Error: MCP tool call failed: bad"},
          {"rpc_failure", "Error: MCP tool call failed: Invalid params: value"},
          {"silent_rpc_failure", "Error: The tool failed while completing the request."},
          {"client_exit", "Error: The tool failed while completing the request."}
        ] do
      descriptor = %{"name" => raw_name, "description" => "Fails", "inputSchema" => %{}}
      assert {:ok, tool} = Tool.create("demo", descriptor, self(), FakeConnection, 123)
      call = %Call{id: "c", name: tool.name(), arguments: %{}}

      assert {:error, %ToolError{} = error} = LibTool.settle(tool, call, %{})
      assert error.content == content

      if content =~ "The tool failed" do
        assert error.message =~ "secret-token"
        refute error.content =~ "secret-token"
      end
    end
  end

  test "normalizes and bounds public names deterministically" do
    first = Tool.public_name("demo", String.duplicate("tool.with.dot", 8))
    second = Tool.public_name("demo", String.duplicate("tool.with.dot", 8))
    unicode = Tool.public_name("demo", String.duplicate("🔧", 30))

    assert first == second
    assert byte_size(first) == 64
    assert byte_size(unicode) <= 64
    assert String.valid?(unicode)
    assert Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, first)
    assert Tool.public_name("demo", "search") == "mcp__demo__search"
  end
end
