defmodule Tackle.Lib.SystemPromptTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.SystemPrompt

  describe "builder" do
    test "composes raw text and titled sections in order" do
      prompt =
        SystemPrompt.new()
        |> SystemPrompt.add_raw("  You are helpful.\n")
        |> SystemPrompt.add_section("Rules", "\nBe concise.\n")
        |> SystemPrompt.to_string()

      assert prompt == "You are helpful.\n\n## Rules\n\nBe concise.\n"
    end

    test "an empty builder renders a single newline" do
      assert SystemPrompt.new() |> SystemPrompt.to_string() == "\n"
    end
  end
end
