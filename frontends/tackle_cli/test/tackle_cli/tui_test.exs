defmodule Tackle.CLI.TUITest do
  use ExUnit.Case, async: true

  alias ExRatatui.Widgets.Paragraph
  alias Tackle.CLI.TUI

  test "welcome widget presents the selected model" do
    assert %Paragraph{text: text} = TUI.welcome_widget("openai-codex/gpt-5.6-sol")
    assert text =~ "Tackle CLI"
    assert text =~ "Model: openai-codex/gpt-5.6-sol"
  end

  test "welcome widget can render without a CLI model override" do
    assert %Paragraph{text: text} = TUI.welcome_widget(nil)
    assert text =~ "Model: configured default"
  end
end
