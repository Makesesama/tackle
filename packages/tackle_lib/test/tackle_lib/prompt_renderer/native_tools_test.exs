defmodule Tackle.Lib.PromptRenderer.NativeToolsTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.PromptRenderer.NativeTools

  defmodule EditTool do
    use Tackle.Lib.Tool

    tool_name("edit")
    description("Edits a file.")

    input do
      field(:path, :string, required: true, description: "File to edit")
      field(:edits, {:list, :map}, required: true, description: "Replacements")
      field(:ratio, :float)
      field(:matrix, {:list, {:list, :integer}}, description: "Rows")
      field(:note, :string, nullable: true, description: "Why")
    end

    def run(args, _context), do: {:ok, args}
  end

  defmodule CustomToolRenderer do
    def render(tool_module), do: "tool #{tool_module.name()}"
  end

  test "renders each tool's definition with its parameters in declaration order" do
    assert NativeTools.render_tools([EditTool], []) ==
             Enum.join(
               [
                 "### edit",
                 "",
                 "Edits a file.",
                 "",
                 "Parameters:",
                 "    - path: string (required) - File to edit",
                 "    - edits: array of object (required) - Replacements",
                 "    - ratio: number - ",
                 "    - matrix: array of array of integer - Rows",
                 "    - note: string - Why",
                 ""
               ],
               "\n"
             )
  end

  test "a :tool_renderer renders each tool module instead" do
    assert NativeTools.render_tools([EditTool, EditTool], tool_renderer: CustomToolRenderer) ==
             "tool edit\ntool edit"
  end
end
