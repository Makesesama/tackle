defmodule Tackle.Review.StagesTest do
  use ExUnit.Case, async: true

  alias Tackle.Review.{Detector, Stages, Verifier}
  alias Tackle.Review.Tools.{ReportFindings, ReportVerdict}

  test "the stages are the profiles the review runs, with their output tools" do
    assert [detector, verifier] = Stages.all()

    assert detector.name == Detector.profile()
    assert verifier.name == Verifier.profile()
    assert ReportFindings.name() in detector.tools
    assert ReportVerdict.name() in verifier.tools

    for stage <- Stages.all() do
      assert is_binary(stage.description) and stage.description != ""
      assert stage.prompt =~ "assignment"
      assert is_integer(stage.max_steps) and stage.max_steps > 0
    end
  end
end
