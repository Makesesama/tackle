defmodule Tackle.Review.RankTest do
  use ExUnit.Case, async: true

  alias Tackle.Review.{Finding, Rank}

  defp finding(fields) do
    struct!(
      Finding,
      Keyword.merge(
        [
          title: "Problem",
          category: :correctness,
          severity: :high,
          blocking: true,
          confidence: 0.9,
          location: %{path: "lib/a.ex", side: :new, start_line: 1, end_line: 1},
          trigger: "t",
          body: "b",
          verdict: :confirmed
        ],
        fields
      )
    )
  end

  test "score weighs severity, confidence, and support" do
    assert_in_delta Rank.score(finding(severity: :blocker, confidence: 1.0)), 1.0, 1.0e-9
    assert_in_delta Rank.score(finding(severity: :low, confidence: 0.5)), 0.2, 1.0e-9
    assert_in_delta Rank.score(finding(confidence: 1.0, support: 1), 3), 0.4, 1.0e-9
    assert_in_delta Rank.score(finding(confidence: 1.0, support: 3), 3), 0.8, 1.0e-9
  end

  test "the default profile shows blocking findings and confident confirmed optional ones" do
    blocking = finding(title: "blocking", verdict: :uncertain, confidence: 0.6)
    low = finding(title: "low", confidence: 0.4)
    optional = finding(title: "optional", blocking: false, confidence: 0.85)
    weak_optional = finding(title: "weak", blocking: false, confidence: 0.7)
    unsure_optional = finding(title: "unsure", blocking: false, verdict: :uncertain)

    selection = Rank.select([low, optional, weak_optional, unsure_optional, blocking], :default)

    assert selection.blocking == [blocking]
    assert selection.optional == [optional]

    assert Enum.sort(selection.dropped) ==
             Enum.sort([
               {low, :below_threshold},
               {weak_optional, :below_threshold},
               {unsure_optional, :uncertain}
             ])
  end

  test "quiet hides optional and uncertain findings; assertive shows them" do
    findings = [
      confirmed = finding(title: "confirmed"),
      uncertain = finding(title: "uncertain", verdict: :uncertain),
      optional = finding(title: "optional", blocking: false, confidence: 0.4)
    ]

    quiet = Rank.select(findings, :quiet)
    assert quiet.blocking == [confirmed]
    assert quiet.optional == []
    assert {uncertain, :uncertain} in quiet.dropped
    assert {optional, :hidden_lane} in quiet.dropped

    assertive = Rank.select(findings, :assertive)
    assert [_, _] = assertive.blocking
    assert assertive.optional == [optional]
  end

  test "orders by score and caps the change, keeping blocking findings first" do
    # Rank.select sorts its input, so the optional finding can lead the list.
    findings = [
      finding(title: "opt", blocking: false, confidence: 1.0)
      | for i <- 1..7 do
          finding(title: "f#{i}", confidence: 0.7 + i / 100, severity: :blocker)
        end
    ]

    selection = Rank.select(findings, :quiet)

    assert Enum.map(selection.blocking, & &1.title) == ["f7", "f6", "f5", "f4", "f3"]
    assert Enum.count(selection.dropped, &match?({_, :over_cap}, &1)) == 2
    assert Enum.any?(selection.dropped, &match?({%{title: "opt"}, :hidden_lane}, &1))

    assertive =
      Rank.select(
        Enum.map(1..60, &finding(title: "f#{&1}", confidence: 0.5 + &1 / 200)),
        :assertive
      )

    assert Enum.count_until(assertive.blocking, 51) == 50
    assert hd(assertive.blocking).title == "f60"
    assert Enum.count(assertive.dropped, &match?({_, :over_cap}, &1)) == 10
  end

  describe "preselect/3" do
    test "drops hidden lanes and keeps the best candidates up to the limit, in order" do
      a = finding(title: "a", confidence: 0.5, verdict: nil)
      b = finding(title: "b", confidence: 0.9, verdict: nil)
      optional = finding(title: "optional", blocking: false, verdict: nil)
      c = finding(title: "c", confidence: 0.7, verdict: nil)

      assert {[^a, ^b, ^c], [{^optional, :hidden_lane}]} =
               Rank.preselect([a, b, optional, c], :quiet)

      assert {[^b, ^c], [{^optional, :hidden_lane}, {^a, :over_verify_limit}]} =
               Rank.preselect([a, b, optional, c], :quiet, limit: 2)

      assert {[^b, ^optional], [{^a, :over_verify_limit}, {^c, :over_verify_limit}]} =
               Rank.preselect([a, b, optional, c], :assertive, limit: 2)
    end

    test "the default limit is twice the profile's cap" do
      assert Rank.verify_limit(:quiet) == 10
      assert Rank.verify_limit(:default) == 30

      candidates = for i <- 1..12, do: finding(title: "#{i}", confidence: i / 12)
      {kept, dropped} = Rank.preselect(candidates, :quiet)
      assert length(kept) == 10

      assert Enum.map(dropped, fn {finding, :over_verify_limit} -> finding.title end) == [
               "1",
               "2"
             ]
    end
  end

  test "profiles and thresholds" do
    assert Rank.profiles() == [:quiet, :default, :assertive]
    assert %{cap: 15, optional: %{min_confidence: 0.8}} = Rank.thresholds(:default)
  end
end
