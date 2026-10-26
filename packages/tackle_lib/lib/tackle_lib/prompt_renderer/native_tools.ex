defmodule Tackle.Lib.PromptRenderer.NativeTools do
  @moduledoc """
  Default prompt renderer for Tackle.Lib's native tool-calling protocol.

  Tools are provided to the model through the LLM adapter's native `tools`
  option. This renderer only adds human-readable guidance and tool descriptions
  to the prompt; it never asks the model to emit JSON tool calls.

  Each tool is rendered from its definition (`Tackle.Lib.Tool.definition/1`),
  the JSON Schema the provider also receives, as a block with its name, its
  description, and one line per parameter in declaration order. A
  `:tool_renderer` option, a module with `render/1`, renders each tool module
  instead.

  JSON schemas are still used internally for tool input definitions and may be
  used by adapters for structured non-tool responses. They are not used as a
  tool-calling protocol.
  """

  @behaviour Tackle.Lib.PromptRenderer

  alias Tackle.Lib.Tool

  @impl Tackle.Lib.PromptRenderer
  def render_tools(tools, opts) do
    render =
      case Keyword.get(opts, :tool_renderer) do
        nil -> &render_tool/1
        tool_renderer -> &tool_renderer.render/1
      end

    Enum.map_join(tools, "\n", render)
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

  defp render_tool(tool_module) do
    %{name: name, description: description, input_schema: input_schema} =
      Tool.definition(tool_module)

    """
    ### #{name}

    #{description}

    Parameters:
    #{render_params(tool_module, input_schema)}
    """
  end

  # JSON Schema properties are a map; the keyword schema they were projected
  # from keeps the order the tool declared them in.
  defp render_params(tool_module, %{"properties" => properties, "required" => required}) do
    Enum.map_join(tool_module.parameters_schema(), "\n", fn {field, _opts} ->
      name = to_string(field)
      schema = Map.fetch!(properties, name)
      required = if name in required, do: " (required)", else: ""
      "    - #{name}: #{render_type(schema)}#{required} - #{schema["description"]}"
    end)
  end

  defp render_type(%{"type" => [type, "null"]} = schema),
    do: render_type(%{schema | "type" => type})

  defp render_type(%{"type" => "array", "items" => items}), do: "array of #{render_type(items)}"
  defp render_type(%{"type" => type}), do: type
end
