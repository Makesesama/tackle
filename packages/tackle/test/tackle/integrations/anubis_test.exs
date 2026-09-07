defmodule Tackle.Integrations.AnubisTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Frame
  alias Tackle.Integrations.Anubis
  alias Tackle.Integrations.Anubis.Schema

  defmodule SearchTool do
    use Tackle.Tool

    tool_name("search")
    description("Search indexed documents.")

    input do
      field :query, :string, required: true, description: "Search query"
      field :limit, :integer, default: 10
    end

    output do
      field :results, {:list, :map}, required: true
      field :user_id, :string
    end

    def run(%{"query" => query, "limit" => limit}, %{user_id: user_id}) do
      {:ok, %{"results" => [%{"query" => query, "limit" => limit}], "user_id" => user_id}}
    end
  end

  defmodule TextTool do
    use Tackle.Tool

    tool_name("text")
    description("Returns a text response.")

    input do
      field :value, :string, required: true
    end

    def run(%{"value" => value}, _context), do: {:ok, value}
  end

  test "Schema.to_peri/1 projects Tackle schemas for Anubis registration" do
    assert %{
             query: {:required, {:meta, :string, [description: "Search query"]}},
             limit: {:integer, {:default, 10}}
           } = Schema.to_peri(SearchTool.parameters_schema())

    assert %{level: {:enum, [1, 2], [type: :integer]}} =
             Schema.to_peri(level: [type: :integer, enum: [1, 2]])
  end

  test "register_all/3 registers Tackle tools on the Anubis frame" do
    frame = Anubis.register_all(Frame.new(), [SearchTool], annotations: %{read_only: true})

    assert %{"search" => tool} = frame.tools
    assert tool.name == "search"
    assert tool.description == "Search indexed documents."
    assert tool.annotations == %{read_only: true}
    assert is_function(tool.validate_input, 1)
  end

  test "dispatch/4 validates args, builds context, and returns structured tool responses" do
    frame = Frame.new(%{user_id: "user-1"})

    assert {:reply, response, ^frame} =
             Anubis.dispatch("search", %{"query" => "videos", "limit" => "3"}, frame,
               tools: [SearchTool],
               context: fn frame -> %{user_id: frame.assigns.user_id} end,
               call_id: "call_1"
             )

    assert response.isError == false

    assert response.structured_content == %{
             "results" => [%{"query" => "videos", "limit" => 3}],
             "user_id" => "user-1"
           }
  end

  test "dispatch/4 returns Anubis error responses for validation failures" do
    frame = Frame.new()

    assert {:reply, response, ^frame} =
             Anubis.dispatch("search", %{}, frame, tools: [SearchTool], call_id: "call_1")

    assert response.isError == true
    assert [%{"text" => message}] = response.content
    assert message =~ "Invalid tool arguments"
  end

  test "dispatch/4 supports non-map tool results as text responses" do
    frame = Frame.new()

    assert {:reply, response, ^frame} =
             Anubis.dispatch("text", %{"value" => "hello"}, frame,
               tools: [TextTool],
               call_id: "call_1"
             )

    assert response.isError == false
    assert response.structured_content == nil
    assert [%{"text" => "hello"}] = response.content
  end

  test "dispatch/4 reports unknown tools without owning protocol error mapping" do
    assert {:error, :unknown_tool} =
             Anubis.dispatch("missing", %{}, Frame.new(), tools: [SearchTool])
  end
end
