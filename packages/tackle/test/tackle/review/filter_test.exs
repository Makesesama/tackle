defmodule Tackle.Review.FilterTest do
  use ExUnit.Case, async: true

  alias Tackle.Review.{Filter, Finding, Rules}

  @changed %{"lib/a.ex" => %{new: [10..12], old: []}}

  defp finding(fields) do
    struct!(
      Finding,
      Keyword.merge(
        [
          title: "Handle the error",
          category: :correctness,
          severity: :high,
          blocking: true,
          confidence: 0.5,
          location: %{path: "lib/a.ex", side: :new, start_line: 10, end_line: 12},
          trigger: "missing file",
          body: "The error is ignored.",
          fingerprint: "fp"
        ],
        fields
      )
    )
  end

  defp rule(id, status) do
    contents = """
    ---
    id: #{id}
    category: correctness
    severity: high
    status: #{status}
    ---
    Body.
    """

    {:ok, rule} = Rules.parse(contents, "#{id}.md", :project)
    rule
  end

  test "keeps findings that pass every filter" do
    kept = finding(rule_id: "active")

    assert {[^kept], []} =
             Filter.deterministic([kept], changed: @changed, rules: [rule("active", "active")])
  end

  test "drops findings with the reason, in order" do
    findings = [
      off = finding(location: %{path: "lib/a.ex", side: :new, start_line: 20, end_line: 21}),
      unknown = finding(rule_id: "missing"),
      inactive = finding(rule_id: "old"),
      style = finding(category: :readability, fingerprint: "style"),
      known = finding(fingerprint: "seen"),
      weak = finding(confidence: 0.1, fingerprint: "weak"),
      kept = finding(fingerprint: "kept")
    ]

    assert {[^kept], dropped} =
             Filter.deterministic(findings,
               changed: @changed,
               rules: [rule("old", "retired")],
               suppressed_categories: [:readability],
               known_fingerprints: MapSet.new(["seen"])
             )

    assert dropped == [
             {off, :not_on_changed_lines},
             {unknown, :unknown_rule},
             {inactive, :inactive_rule},
             {style, :suppressed_category},
             {known, :known},
             {weak, :low_confidence}
           ]
  end

  test "confidence floors are per category" do
    style = finding(category: :readability, confidence: 0.25)
    bug = finding(confidence: 0.25)

    assert {[^bug], [{^style, :low_confidence}]} = Filter.deterministic([style, bug])
    assert {[], [_, _]} = Filter.deterministic([style, bug], min_confidence: 0.5)

    assert {[^style], [{^bug, :low_confidence}]} =
             Filter.deterministic([style, bug],
               min_confidence: %{correctness: 0.9, readability: 0.1}
             )
  end

  test "without :changed or :rules those checks are skipped" do
    f =
      finding(rule_id: "anything", location: %{path: "x", side: :new, start_line: 1, end_line: 1})

    assert {[^f], []} = Filter.deterministic([f])
  end
end
