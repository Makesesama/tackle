defmodule Tackle.Lib.SystemPromptTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.SystemPrompt

  defmodule TestTool do
    @behaviour Tackle.Lib.Tool

    @impl true
    def name, do: "test_tool"

    @impl true
    def description, do: "A test tool"

    @impl true
    def parameters_schema, do: [query: [type: :string, required: true]]

    @impl true
    def execute(_args, _context), do: {:ok, "ok"}
  end

  defmodule CustomPromptRenderer do
    @behaviour Tackle.Lib.PromptRenderer

    @impl true
    def render_tools(tools, opts) do
      prefix = Keyword.get(opts, :prefix, "tool")

      Enum.map_join(tools, "\n", fn tool -> "#{prefix}: #{tool.name()}" end)
    end

    @impl true
    def render_response_format(opts) do
      Keyword.get(opts, :response_text, "Return YAML only.")
    end

    @impl true
    def response_schema(opts) do
      Keyword.get(opts, :schema)
    end
  end

  describe "builder" do
    test "composes raw text, sections, tools, and response format" do
      prompt =
        SystemPrompt.new()
        |> SystemPrompt.add_raw("You are helpful.")
        |> SystemPrompt.add_section("Rules", "Be concise.")
        |> SystemPrompt.add_tools([TestTool])
        |> SystemPrompt.add_response_format()
        |> SystemPrompt.to_string()

      assert prompt =~ "You are helpful."
      assert prompt =~ "## Rules\n\nBe concise."
      assert prompt =~ "## Available Tools"
      assert prompt =~ "### test_tool"
      assert prompt =~ "## Responding"
    end

    test "lets hosts customize tool and response rendering through one prompt renderer" do
      opts = [
        prompt_renderer: CustomPromptRenderer,
        prompt_renderer_opts: [prefix: "capability", response_text: "Return YAML only."]
      ]

      prompt =
        SystemPrompt.new()
        |> SystemPrompt.add_tools(
          [TestTool],
          Keyword.put(opts, :title, "Capabilities")
        )
        |> SystemPrompt.add_response_format(opts)
        |> SystemPrompt.to_string()

      assert prompt =~ "## Capabilities"
      assert prompt =~ "capability: test_tool"
      assert prompt =~ "Return YAML only."
      refute prompt =~ "## Response Format (STRICT)"
    end
  end

  describe "prompt renderer" do
    test "response schema comes from the selected prompt renderer" do
      opts = [
        prompt_renderer: CustomPromptRenderer,
        prompt_renderer_opts: [schema: [answer: [type: :string]]]
      ]

      assert SystemPrompt.response_schema(opts) == [answer: [type: :string]]
    end

    test "default renderer uses native tools without a JSON response schema" do
      assert SystemPrompt.response_schema() == nil
    end
  end

  describe "version_id/1" do
    test "returns nil for nil" do
      assert SystemPrompt.version_id(nil) == nil
    end

    test "is deterministic" do
      id1 = SystemPrompt.version_id("hello")
      id2 = SystemPrompt.version_id("hello")
      assert id1 == id2
    end

    test "different prompts produce different ids" do
      id1 = SystemPrompt.version_id("Prompt A")
      id2 = SystemPrompt.version_id("Prompt B")
      assert id1 != id2
    end

    test "produces 16-char hex string" do
      id = SystemPrompt.version_id("hello")
      assert is_binary(id)
      assert String.length(id) == 16
    end
  end
end
