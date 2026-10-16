defmodule Tackle.ToolsTest do
  use ExUnit.Case, async: true

  alias Tackle.Review.Tools.{ReportFindings, ReportVerdict}
  alias Tackle.Tools
  alias Tackle.Tools.{Bash, Edit, Read, Write}

  test "exposes the four default tools" do
    assert Tools.default() == [Read, Bash, Edit, Write]
    assert Enum.map(Tools.default(), & &1.name()) == ["read", "bash", "edit", "write"]
  end

  test "lists the review output tools separately" do
    assert Tools.review() == [ReportFindings, ReportVerdict]
  end
end
