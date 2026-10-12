defmodule Tackle.Review.ClusterTest do
  use ExUnit.Case, async: true

  alias Tackle.Review.{Cluster, Finding}

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
          body: "The error is ignored."
        ],
        fields
      )
    )
  end

  test "merges overlapping findings with the same rule across samples and counts support" do
    a = finding(rule_id: "unhandled-error", confidence: 0.6)

    b =
      finding(
        rule_id: "unhandled-error",
        confidence: 0.9,
        title: "Do not ignore File.read errors",
        location: %{path: "lib/a.ex", side: :new, start_line: 12, end_line: 14}
      )

    assert [merged] = Cluster.merge([[a], [b]])
    assert merged.title == "Do not ignore File.read errors"
    assert merged.support == 2
  end

  test "duplicates within one sample do not add support" do
    a = finding(confidence: 0.6)
    b = finding(confidence: 0.6, body: "Short.")

    assert [merged] = Cluster.merge([[a, b]])
    assert merged.support == 1
    assert merged.body == "Short."
  end

  test "keeps findings apart with different keys, paths, sides, or ranges" do
    base = finding([])

    others = [
      finding(category: :security),
      finding(rule_id: "unhandled-error"),
      finding(location: %{path: "lib/b.ex", side: :new, start_line: 10, end_line: 12}),
      finding(location: %{path: "lib/a.ex", side: :old, start_line: 10, end_line: 12}),
      finding(location: %{path: "lib/a.ex", side: :new, start_line: 13, end_line: 15})
    ]

    assert [_, _, _, _, _, _] = Cluster.merge([[base | others]])
  end

  test "merges findings with the same fingerprint even when locations differ" do
    a = finding(fingerprint: "abc")

    b =
      finding(
        fingerprint: "abc",
        location: %{path: "lib/a.ex", side: :new, start_line: 30, end_line: 30}
      )

    assert [%Finding{support: 2}] = Cluster.merge([[a], [b]])
  end

  test "an empty input has no clusters" do
    assert Cluster.merge([]) == []
    assert Cluster.merge([[], []]) == []
  end
end
