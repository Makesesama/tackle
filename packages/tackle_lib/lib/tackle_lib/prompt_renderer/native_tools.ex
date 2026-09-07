defmodule Tackle.Lib.PromptRenderer.NativeTools do
  @moduledoc """
  Default prompt renderer for Tackle.Lib's native tool-calling protocol.

  Tools are provided to the model through the LLM adapter's native `tools`
  option. This renderer only adds human-readable guidance and tool descriptions
  to the prompt; it never asks the model to emit JSON tool calls.

  JSON schemas are still used internally for tool input definitions and may be
  used by adapters for structured non-tool responses. They are not used as a
  tool-calling protocol.
  """

  @behaviour Tackle.Lib.PromptRenderer

  alias Tackle.Lib.Tool

  @impl Tackle.Lib.PromptRenderer
  def render_tools(tools, opts) do
    description_renderer = Keyword.get(opts, :description_renderer)
    tool_renderer = Keyword.get(opts, :tool_renderer)

    Enum.map_join(tools, "\n", fn tool ->
      render_tool_description(tool, tool_renderer, description_renderer)
    end)
  end

  @impl Tackle.Lib.PromptRenderer
  def render_response_format(_opts) do
    """
    ## Responding

    Use the provider-native tool-calling interface when you need information or
    need to act. Do not write tool calls as JSON, XML, markdown, or prose.

    When you have enough information, answer the user directly in clear natural
    language. Do not wrap the final answer in JSON or code fences unless a
    separate structured-output schema is explicitly requested.

    In a single turn, either call tools or provide a final answer. After tool
    results come back, continue until you can answer.
    """
    |> String.trim()
  end

  @impl Tackle.Lib.PromptRenderer
  def response_schema(_opts), do: nil

  defp render_tool_description(tool, nil, description_renderer) do
    Tool.build_tool_description(tool, description_renderer)
  end

  defp render_tool_description(tool, tool_renderer, nil) do
    tool_renderer.render(tool)
  end

  defp render_tool_description(tool, tool_renderer, description_renderer) do
    if function_exported?(tool_renderer, :render, 2) do
      tool_renderer.render(tool, description_renderer)
    else
      tool_renderer.render(tool)
    end
  end
end
