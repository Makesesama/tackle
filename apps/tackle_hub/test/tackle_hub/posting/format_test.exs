defmodule Tackle.Hub.Posting.FormatTest do
  use ExUnit.Case, async: true

  alias Tackle.Hub.Posting.Format
  alias Tackle.Hub.Reviews.Finding

  @run_id "5d3c8a2e-0f4b-4c1a-9a63-2b7f1e0d9c41"
  @zwsp "\u200B"

  # Lines 10-14 on both sides, with one removed line (old 12) and one added
  # line (new 12): old 10 11 12 13 14 / new 10 11 12 13 14.
  @patch """
  @@ -10,5 +10,5 @@ def run
   context ten
   context eleven
  -removed twelve
  +added twelve
   context thirteen
   context fourteen
  @@ -40,2 +40,3 @@
   forty
  +forty-one
   forty-two
  """

  defp request(attrs \\ %{}), do: Map.merge(%{profile: :default}, attrs)

  defp run(attrs \\ %{}) do
    Map.merge(%{id: @run_id, verdict: :blocking, summary: %{"units" => 3}}, attrs)
  end

  defp fingerprint(n), do: :crypto.hash(:sha256, "f#{n}") |> Base.encode16(case: :lower)

  defp finding(attrs \\ %{}) do
    Map.merge(
      %{
        fingerprint: fingerprint(1),
        state: :shown,
        title: "Handle the empty list",
        category: :correctness,
        severity: :high,
        blocking: true,
        path: "lib/app.ex",
        side: :new,
        start_line: 12,
        end_line: 12,
        trigger: "an empty list",
        body: "The function crashes.",
        suggestion: nil
      },
      attrs
    )
  end

  defp files, do: [%{path: "lib/app.ex", patch: @patch}]

  defp build(findings, files \\ files(), known \\ MapSet.new(), opts \\ []) do
    Format.build(
      Keyword.get(opts, :request, request()),
      Keyword.get(opts, :run, run()),
      findings,
      files,
      known
    )
  end

  defp marker(fp), do: "<!-- tackle-finding:#{fp} -->"

  describe "markers" do
    test "the body starts with the exact run marker; comments with the finding marker" do
      result = build([finding()])

      assert String.starts_with?(result.body, "<!-- tackle-review:#{@run_id} -->\n")
      assert [%{body: comment}] = result.comments
      assert String.starts_with?(comment, marker(fingerprint(1)) <> "\n")
      assert result.fingerprints == [fingerprint(1)]
    end

    test "a run id that could not form a safe marker raises" do
      for id <- [nil, "", "x --> <b>", "a\nb", String.duplicate("a", 65), 42] do
        assert_raise ArgumentError, fn ->
          build([finding()], files(), MapSet.new(), run: run(%{id: id}))
        end
      end
    end

    test "findings without a valid fingerprint are left out and counted" do
      bad = [
        "x --> @everyone",
        "DEADBEEFDEADBEEFDEADBEEF",
        "abc",
        nil,
        String.duplicate("a", 65)
      ]

      findings = [finding() | Enum.map(bad, &finding(%{fingerprint: &1}))]
      result = build(findings)

      assert result.fingerprints == [fingerprint(1)]
      assert [_] = result.comments
      assert result.body =~ "5 findings without a valid fingerprint are left out."
      refute result.body =~ "everyone"
      assert count(result.body, "<!--") == 1
    end
  end

  describe "placement" do
    test "an added line on the new side becomes a single-line comment" do
      assert [%{path: "lib/app.ex", side: :new, line: 12} = comment] =
               build([finding()]).comments

      refute Map.has_key?(comment, :start_line)
    end

    test "context lines can be commented on either side; removed lines only on the old" do
      sides = [
        {:new, 11, true},
        {:old, 11, true},
        {:old, 12, true},
        {:new, 14, true},
        {:old, 14, true},
        {:new, 41, true},
        {:old, 41, true},
        {:old, 42, false},
        {:new, 42, true},
        {:new, 15, false},
        {:new, 9, false},
        {:old, 43, false}
      ]

      for {side, line, commented?} <- sides do
        result = build([finding(%{side: side, start_line: line, end_line: line})])
        assert result.comments != [] == commented?, "#{side} #{line}"

        if commented?, do: assert([%{side: ^side, line: ^line}] = result.comments)
      end
    end

    test "a range in one hunk keeps its start line; across hunks only the end line" do
      assert [%{line: 13, start_line: 10}] =
               build([finding(%{start_line: 10, end_line: 13})]).comments

      assert [comment] = build([finding(%{start_line: 12, end_line: 41})]).comments
      assert %{line: 41} = comment
      refute Map.has_key?(comment, :start_line)

      # The start lies outside every hunk.
      assert [comment] = build([finding(%{start_line: 5, end_line: 11})]).comments
      refute Map.has_key?(comment, :start_line)

      # A reversed range comments on the end line only.
      assert [comment] = build([finding(%{start_line: 14, end_line: 11})]).comments
      assert %{line: 11} = comment
      refute Map.has_key?(comment, :start_line)
    end

    test "an end line outside the diff goes into the body even when the start is in it" do
      result = build([finding(%{start_line: 13, end_line: 20})])
      assert result.comments == []
      assert result.body =~ marker(fingerprint(1))
      assert result.body =~ "lines 13–20"
      assert result.fingerprints == [fingerprint(1)]
    end

    test "no files, unknown paths, and absent patches fall back to the body" do
      for files <- [[], [%{path: "other.ex", patch: @patch}], [%{path: "lib/app.ex", patch: nil}]] do
        result = build([finding()], files)
        assert result.comments == []
        assert result.body =~ marker(fingerprint(1))
        assert result.body =~ "In `lib/app.ex`, line 12."
        assert result.fingerprints == [fingerprint(1)]
      end

      assert [] = build([finding()], [%{path: "lib/app.ex"}]).comments
    end

    test "an invalid side or line goes into the body" do
      for attrs <- [
            %{side: :left},
            %{side: "new"},
            %{end_line: 0},
            %{end_line: nil},
            %{path: nil}
          ] do
        result = build([finding(attrs)])
        assert result.comments == []
        assert result.fingerprints == [fingerprint(1)]
      end
    end

    test "a missing end line does not render a dangling range" do
      result = build([finding(%{start_line: 12, end_line: nil})])
      assert result.body =~ "In `lib/app.ex`."
      refute result.body =~ "lines 12–"
    end

    test "the first file entry for a path is used" do
      files = [%{path: "lib/app.ex", patch: nil}, %{path: "lib/app.ex", patch: @patch}]
      assert build([finding()], files).comments == []
    end
  end

  describe "hunks/1" do
    test "gives each hunk's lines on the old and new side" do
      assert Format.hunks(@patch) == [
               %{old: 10..14//1, new: 10..14//1},
               %{old: 40..41//1, new: 40..42//1}
             ]
    end

    test "omitted counts default to one; zero counts are empty" do
      assert Format.hunks("@@ -3 +3 @@\n-a\n+b") == [%{old: 3..3//1, new: 3..3//1}]

      assert Format.hunks("@@ -0,0 +1,2 @@\n+a\n+b\n") == [
               %{old: 0..-1//1, new: 1..2//1}
             ]

      assert Format.hunks("@@ -1,2 +0,0 @@\n-a\n-b") == [%{old: 1..2//1, new: 0..-1//1}]
    end

    test "no-newline notes do not count as lines" do
      patch =
        "@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file\n@@ -9 +9 @@\n-x\n+y"

      assert [%{new: 1..1//1}, %{new: 9..9//1}] = Format.hunks(patch)
    end

    test "content that looks like a header is read by the counts" do
      patch = "@@ -1,2 +1,2 @@\n--- a/not-a-header\n+++ b/not-a-header\n context\n"
      assert Format.hunks(patch) == [%{old: 1..2//1, new: 1..2//1}]

      patch = "@@ -1 +1 @@\n--- a\n+++ b\n@@ -5 +5 @@\n-x\n+y"
      assert Format.hunks(patch) == [%{old: 1..1//1, new: 1..1//1}, %{old: 5..5//1, new: 5..5//1}]
    end

    test "a truncated or malformed hunk ends parsing, keeping complete earlier hunks" do
      first = "@@ -1 +1 @@\n-a\n+b\n"
      # A complete hunk followed by a line that is no header is malformed
      # too: its counts may be wrong.
      assert Format.hunks(first <> "+extra\n") == []

      assert Format.hunks(first <> "@@ -9 +9 @@\n-a\n+b\n+extra") == [
               %{old: 1..1//1, new: 1..1//1}
             ]

      for tail <- [
            "@@ -10,5 +10,5 @@\n context\n",
            "@@ -10,1 +10,1 @@\n-a\n\n+b\n",
            "@@ -10,1 +10,1 @@\n*a\n+b\n",
            "@@ -x +y @@\n-a\n+b\n",
            "@@ -0,1 +10,1 @@\n-a\n+b\n",
            "@@ -10 +10 @@\n-a\n+b\n \n"
          ] do
        assert Format.hunks(first <> tail) == [%{old: 1..1//1, new: 1..1//1}], tail
      end

      assert Format.hunks("@@ -1,3 +1,3 @@\n a\n b") == []
    end

    test "skips text before the first hunk and handles absent or empty patches" do
      assert [%{new: 1..1//1}] =
               Format.hunks("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b")

      assert Format.hunks(nil) == []
      assert Format.hunks("") == []
      assert Format.hunks("Binary files differ") == []
    end

    test "a truncated hunk's header lines are not commentable" do
      truncated = "@@ -10,5 +10,5 @@\n context ten\n context eleven\n"

      result =
        build([finding(%{start_line: 11, end_line: 11})], [
          %{path: "lib/app.ex", patch: truncated}
        ])

      assert result.comments == []
    end
  end

  describe "selection" do
    test "only shown findings are posted" do
      findings = [
        finding(%{state: :rejected, fingerprint: fingerprint(2)}),
        finding(%{state: :hidden, fingerprint: fingerprint(3)}),
        Map.delete(finding(%{fingerprint: fingerprint(4)}), :state),
        finding()
      ]

      result = build(findings)
      assert result.fingerprints == [fingerprint(1)]
      refute result.body =~ fingerprint(2)
    end

    test "known fingerprints are mentioned as still present, not posted again" do
      known =
        finding(%{
          fingerprint: fingerprint(2),
          title: "Old @alice problem",
          body: "SECRET DETAIL"
        })

      result = build([known, finding()], files(), MapSet.new([fingerprint(2)]))

      assert result.fingerprints == [fingerprint(1)]
      assert [_] = result.comments
      assert result.body =~ "#### Still present from an earlier review"
      assert result.body =~ "- **Blocking:** Old @#{@zwsp}alice problem (`#{fingerprint(2)}`)"
      refute result.body =~ "SECRET DETAIL"
      refute result.body =~ marker(fingerprint(2))
      assert result.body =~ "1 already reported"
    end

    test "duplicate fingerprints are posted once" do
      result =
        build([finding(), finding(%{title: "Again"}), finding(%{start_line: 41, end_line: 41})])

      assert result.fingerprints == [fingerprint(1)]
      assert [_] = result.comments
    end

    test "accepts stored Finding structs" do
      struct = struct(Finding, finding())
      assert %{fingerprints: [_], comments: [_]} = build([struct])
    end
  end

  describe "body" do
    test "leads with the verdict, counts, profile, and units, and lists blocking first" do
      findings = [
        finding(%{
          fingerprint: fingerprint(2),
          blocking: false,
          severity: :low,
          title: "Optional thing",
          path: "x.ex"
        }),
        finding(%{
          fingerprint: fingerprint(3),
          title: "Blocking elsewhere",
          path: "y.ex",
          severity: :medium
        }),
        finding(%{fingerprint: fingerprint(4), title: "Worst", path: "y.ex", severity: :blocker}),
        finding()
      ]

      result = build(findings)

      assert result.body =~
               "**Tackle review: blocking findings**\n\n" <>
                 "4 findings (3 blocking, 1 optional): 1 as line comments, 3 below.\n" <>
                 "3 units reviewed with the default profile."

      blocking = :binary.match(result.body, "#### Blocking findings") |> elem(0)
      optional = :binary.match(result.body, "#### Optional findings") |> elem(0)
      worst = :binary.match(result.body, "Worst") |> elem(0)
      elsewhere = :binary.match(result.body, "Blocking elsewhere") |> elem(0)
      assert blocking < worst and worst < elsewhere and elsewhere < optional
      assert result.body =~ "**Blocking · blocker · correctness:** Worst"

      assert result.fingerprints == [
               fingerprint(1),
               fingerprint(4),
               fingerprint(3),
               fingerprint(2)
             ]
    end

    test "comments are ordered blocking first" do
      findings = [
        finding(%{fingerprint: fingerprint(2), blocking: false, end_line: 11, start_line: 11}),
        finding(%{fingerprint: fingerprint(3), end_line: 13, start_line: 13})
      ]

      assert [%{line: 13}, %{line: 11}] = build(findings).comments
    end

    test "clean, unknown verdicts, atom summary keys, and missing profile" do
      body = build([], files(), MapSet.new(), run: run(%{verdict: :clean})).body
      assert body =~ "**Tackle review: no findings**\n\nNo findings."

      body =
        build([], files(), MapSet.new(),
          run: run(%{verdict: :weird, summary: %{units: 1}}),
          request: %{profile: :nope}
        ).body

      assert body =~ "**Tackle review: finished**"
      assert body =~ "\n1 unit reviewed."
      refute body =~ "nope"

      body =
        build([], files(), MapSet.new(), run: run(%{summary: nil}), request: %{profile: "quiet"}).body

      assert body =~ "Reviewed with the quiet profile."
    end
  end

  describe "bounds" do
    test "line comments are capped; the rest are listed in the body" do
      findings = for n <- 1..30, do: finding(%{fingerprint: fingerprint(n)})
      result = build(findings)

      assert Enum.count(result.comments) == 25

      assert result.body =~
               "Line comments are limited to 25; 5 more findings on diff lines are listed below."

      assert Enum.count(result.fingerprints) == 30
      for n <- 26..30, do: assert(result.body =~ marker(fingerprint(n)))
    end

    test "the body stays under the limit and reports only complete entries" do
      long = String.duplicate("word ", 300)

      findings =
        for n <- 1..200, do: finding(%{fingerprint: fingerprint(n), body: long, path: "z.ex"})

      known =
        for n <- 201..260,
            do: finding(%{fingerprint: fingerprint(n), title: String.duplicate("t", 300)})

      result = build(findings ++ known, [], MapSet.new(Enum.map(201..260, &fingerprint/1)))

      assert byte_size(result.body) < 60_000
      assert String.starts_with?(result.body, "<!-- tackle-review:#{@run_id} -->")

      assert result.body =~
               ~r/\*\*Truncated:\*\* \d+ findings and 60 earlier findings still present left out/

      assert result.fingerprints != []
      assert Enum.count(result.fingerprints) < 200

      for n <- 1..200 do
        fp = fingerprint(n)
        assert fp in result.fingerprints == (result.body =~ marker(fp))
      end

      # Every reported entry is complete: its body text is followed by the
      # next entry or the notice.
      included = length(result.fingerprints)
      assert count(result.body, String.trim(long)) == included
    end

    test "finding text is capped, with a truncation note" do
      result =
        build([finding(%{body: String.duplicate("a", 5_000), title: String.duplicate("b", 500)})])

      [%{body: comment}] = result.comments
      assert comment =~ String.duplicate("a", 2_000) <> " *(truncated)*"
      refute comment =~ String.duplicate("a", 2_001)
      assert comment =~ String.duplicate("b", 200) <> " *(truncated)*"
    end

    test "worst-case expansion keeps a comment well under the forge limit" do
      nasty = String.duplicate("'@#1 fix", 2_000)
      combining = "e" <> String.duplicate("\u0301", 10_000)

      result =
        build([
          finding(%{
            title: nasty,
            body: nasty <> combining,
            trigger: nasty,
            suggestion: String.duplicate("`@a ", 5_000)
          })
        ])

      [%{body: comment}] = result.comments
      assert byte_size(comment) < 65_536
      assert comment =~ "*(suggestion truncated)*"
    end
  end

  describe "untrusted text" do
    @attacks [
      "@alice please look",
      "cc @org/security-team",
      "\\@escaped",
      "&#64;entity &#x40;hex &commat;named &amp;#64;double",
      "＠fullwidth ﹫small",
      "@\u200Bpre-broken @\u2060joined",
      "fixes #12",
      "Closes: owner/repo#3",
      "resolves https://github.com/o/r/issues/1",
      "FIXED GH-4 and fix\u00AD es #5",
      "<img src=x onerror=alert(1)>",
      "<!-- tackle-finding:#{String.duplicate("a", 32)} -->",
      "<!-- tackle-review:#{@run_id} -->",
      "[click](javascript:alert(1)) ![pixel](https://evil.example/p.png)",
      "<https://evil.example> www.evil.example",
      "**bold** `code` ~~strike~~ $x$ | table |",
      "\u202Eevil bidi\u202C and \u0000 null and \e[31m escape",
      "# Heading\n\n> quote\n\n- list\n1. ordered\n===",
      "user@example.com"
    ]

    test "prose cannot mention, reference, close, link, or inject markup" do
      for attack <- @attacks do
        result =
          build([
            finding(%{title: attack, body: attack, trigger: attack}),
            finding(%{
              fingerprint: fingerprint(2),
              title: attack,
              body: attack,
              trigger: attack,
              path: "x"
            })
          ])

        for text <- [result.body | Enum.map(result.comments, & &1.body)] do
          assert_safe(text, attack)
        end
      end
    end

    test "prose keeps its words" do
      [%{body: comment}] = build([finding(%{body: "Use x < y && z's value"})]).comments
      assert comment =~ "Use x &lt; y &amp;&amp; z&#39;s value"
    end

    test "suggestions are fenced longer than any backtick or tilde run" do
      code = "def f do\n  ```\n  ~~~~~~\n  <div>x</div>\nend\n"
      [%{body: comment}] = build([finding(%{suggestion: code})]).comments

      fence = String.duplicate("`", 7)

      assert comment =~
               "**Suggestion:**\n\n#{fence}\ndef f do\n  ```\n  ~~~~~~\n  <div>x</div>\nend\n#{fence}"

      [%{body: comment}] = build([finding(%{suggestion: "x = 1"})]).comments
      assert comment =~ "```\nx = 1\n```"
    end

    test "code keeps its text but cannot mention, close, or carry markers" do
      code = "@decorator\nemail a@b.c\n# fixes #12\n<!-- tackle-review:#{@run_id} -->\n\u202Ebidi"
      [%{body: comment}] = build([finding(%{suggestion: code})]).comments

      assert comment =~ "@#{@zwsp}decorator"
      assert comment =~ "a@#{@zwsp}b.c"
      assert comment =~ "# f#{@zwsp}ixes #12"
      assert comment =~ "<#{@zwsp}!-- tackle-review:"
      refute comment =~ "\u202E"
      assert count(comment, "<!--") == 1
    end

    test "paths go into code spans that their backticks cannot close" do
      result = build([finding(%{path: "a`b``c @x\nfixes #1"})], [])
      assert result.body =~ "In ```a`b``c @#{@zwsp}x f#{@zwsp}ixes #1```, line 12."

      result = build([finding(%{path: "`edge` "})], [])
      assert result.body =~ "In `` `edge`  ``, line 12."
    end
  end

  defp assert_safe(text, attack) do
    markers = count(text, "<!-- tackle-")
    message = "unsafe output for #{inspect(attack)}:\n#{text}"

    # The only HTML is our markers, one per line at the start of an entry.
    assert count(text, "<") == markers, message
    assert count(text, ">") == markers, message

    assert Regex.scan(~r/^<!-- tackle-(?:review|finding):[0-9a-f-]+ -->$/m, text) |> length() ==
             markers

    # Every entity is one we produced from an escaped character.
    refute text =~ ~r/&(?!amp;|lt;|gt;|quot;|#39;)/, message

    # Every @ (including fullwidth forms) is followed by a zero-width space.
    refute text =~ ~r/[@\x{FF20}\x{FE6B}](?!\x{200B})/u, message

    # No issue reference, URL, or closing keyword can form.
    refute text =~ ~r/#\d/, message
    refute text =~ ~r/GH-\d/i, message
    refute text =~ ~r/:\/\//, message

    refute text =~ ~r/(?<![A-Za-z0-9])(close[sd]?|fix(es|ed)?|resolve[sd]?)(?![A-Za-z0-9])/i,
           message

    # No link or image syntax, and no invisible or control characters
    # other than our zero-width spaces.
    refute text =~ ~r/(?<!\\)[\[\]]/, message

    refute text =~ ~r/[\x{202A}-\x{202E}\x{2066}-\x{2069}\x{00AD}\x{2060}\x{0000}\x{001B}]/u,
           message
  end

  defp count(text, pattern), do: length(:binary.matches(text, pattern))
end
