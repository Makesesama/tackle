defmodule Tackle.ConfigTest do
  use ExUnit.Case, async: true

  alias Tackle.Config
  alias Tackle.Lib.LLM.Selection

  defmodule Adapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "test"

    @impl true
    def models, do: ["small", "family/nested"]

    @impl true
    def generate(_schema, _opts), do: {:error, :not_used}
  end

  defmodule Tool do
    use Tackle.Lib.Tool

    tool_name("test_tool")
    description("A test tool.")

    input do
      field(:value, :string, required: true)
    end

    def run(%{"value" => value}, _context), do: {:ok, %{value: value}}
  end

  defmodule DuplicateTool do
    use Tackle.Lib.Tool

    tool_name("test_tool")
    description("A duplicate test tool.")

    input do
      field(:value, :string, required: true)
    end

    def run(%{"value" => value}, _context), do: {:ok, %{value: value}}
  end

  test "resolves an explicit adapter and canonical model reference" do
    assert {:ok, config} =
             Config.new(
               adapters: [Adapter],
               model: "test/family/nested",
               tools: [Tool],
               context: %{workspace: "/tmp/project"},
               llm_stream: true
             )

    assert %Selection{
             adapter: Adapter,
             adapter_id: "test",
             model: "family/nested",
             ref: "test/family/nested"
           } = config.llm

    assert config.model_ref == "test/family/nested"
    assert config.tools == [Tool]
    assert config.context == %{workspace: "/tmp/project"}
    assert config.llm_stream

    state = Config.to_agent_state(config)
    assert state.llm == config.llm
    assert state.model == "family/nested"
  end

  test "uses the built-in developer tools by default and permits an explicit empty set" do
    assert {:ok, config} = Config.new(adapters: [Adapter], model: "test/small")
    assert config.tools == Tackle.Tools.default()

    assert {:ok, config} = Config.new(adapters: [Adapter], model: "test/small", tools: [])
    assert config.tools == []
  end

  test "returns explicit validation errors" do
    assert {:error, {:missing_option, :adapters}} = Config.new(model: "test/small")

    assert {:error, {:unknown_model, "test/missing"}} =
             Config.new(adapters: [Adapter], model: "test/missing")

    assert {:error, {:unknown_options, [:surprise]}} =
             Config.new(adapters: [Adapter], model: "test/small", surprise: true)

    assert {:error, {:duplicate_option, :model}} =
             Config.new(adapters: [Adapter], model: "test/small", model: "test/small")

    assert {:error, {:duplicate_tool_name, "test_tool"}} =
             Config.new(
               adapters: [Adapter],
               model: "test/small",
               tools: [Tool, DuplicateTool]
             )

    assert {:error, {:reserved_llm_option, :credential_store}} =
             Config.new(
               adapters: [Adapter],
               model: "test/small",
               llm_opts: [credential_store: {:not, :allowed}]
             )

    assert {:error, {:reserved_llm_option, :access_token}} =
             Config.new(
               adapters: [Adapter],
               model: "test/small",
               llm_opts: [access_token: "must-not-enter-config"]
             )

    assert {:error, {:reserved_llm_option, "api_key"}} =
             Config.new(
               adapters: [Adapter],
               model: "test/small",
               llm_opts: [provider: %{"api_key" => "must-not-enter-config"}]
             )
  end
end
