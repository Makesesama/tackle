defmodule Tackle.Hub.Posting.Format do
  @moduledoc """
  The text of a posted review: its body and line comments
  (docs/TACKLE_HUB_PLAN.md §7.5.1).

  Pure and forge-neutral: it builds data and makes no forge calls, so a
  later forge reuses it. A forge module maps `side` to its own terms
  (`Tackle.Hub.Forge.GitHub` sends `:new` as `RIGHT` and `:old` as `LEFT`).

  ## Placement

  A finding becomes a line comment when its end line is a line of the
  file's diff on the finding's side: an added or context line for `:new`,
  a removed or context line for `:old`. `start_line` is set when the range
  spans lines and its first line lies in the same hunk; otherwise the
  comment is on the end line only. A patch is only trusted up to its first
  malformed or truncated hunk (one whose lines do not match its `@@`
  counts); later hunks are ignored. Findings on files without a patch,
  outside the diff, or beyond the line-comment cap go into the body. With
  no files at all, every finding goes into the body.

  ## Model output is untrusted

  Finding text was written by a model that read the pull request, so it
  is turned into plain prose: control and invisible format characters are
  removed, HTML and Markdown punctuation are escaped (so no link, image,
  HTML, comment, or entity survives), `@` is followed by a zero-width
  space (no mention can form, whatever escape or entity produced it), and
  issue references (`#1`, `GH-1`, URLs) and closing keywords are broken
  the same way. Code (suggestions, paths) goes into fences or code spans
  longer than any backtick or tilde run inside it; in code, `<!--`,
  mention-like `@`, and closing keywords followed by an issue reference
  get a zero-width space too, so copied code may contain one.

  ## Markers and bounds

  The body starts with `<!-- tackle-review:<run id> -->`; every finding's
  comment, and its body entry when it has none, starts with
  `<!-- tackle-finding:<fingerprint> -->`. Run ids and fingerprints are
  validated before they go into a marker; a finding whose fingerprint is
  not lowercase hex is left out and counted in the body.

  Each finding's text is capped, at most 25 findings become line
  comments, and the body stays under 60,000 bytes (below GitHub's 65,536
  characters). What is cut is said in the body. The returned
  `fingerprints` are exactly the findings posted in full by this review:
  a line comment or a complete body entry. Already known fingerprints,
  duplicates, and cut entries are not in it.
  """

  alias Tackle.Review.Rank

  @zwsp "\u200B"

  @max_comments 25
  @max_body_bytes 60_000
  @notice_reserve 1_000

  @max_title 200
  @max_list_title 120
  @max_text 2_000
  @max_trigger 1_000
  @max_suggestion 4_000

  @severities [:blocker, :high, :medium, :low]
  @categories [:correctness, :security, :performance, :maintainability, :readability, :testing]
  @verdicts %{
    blocking: "blocking findings",
    optional: "optional findings only",
    clean: "no findings"
  }

  @fingerprint ~r/\A[0-9a-f]{16,64}\z/
  @run_id ~r/\A[0-9A-Za-z][0-9A-Za-z-]{0,63}\z/
  @hunk_header ~r/\A@@ -(\d{1,9})(?:,(\d{1,9}))? \+(\d{1,9})(?:,(\d{1,9}))? @@(?: |\z)/

  @keyword "(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)"
  @prose_keyword Regex.compile!("(?<![A-Za-z0-9])(#{@keyword})(?![A-Za-z0-9])", "iu")
  @code_keyword Regex.compile!(
                  "(?<![A-Za-z0-9])(#{@keyword})(?=\\s*:?\\s*(?:[\\w.-]+/[\\w.-]+)?(?:#|GH-)\\d|\\s*:?\\s*https?:)",
                  "iu"
                )

  # Escaped with a backslash in prose; `&<>"'` become entities instead.
  @markdown ~c"\\`*_{}[]()#+-.!|~^:$=/"

  @typedoc "A file changed by the pull request; `patch` is its diff hunks, if any."
  @type file :: %{required(:path) => String.t(), optional(:patch) => String.t() | nil}

  @typedoc "A line comment, as `Tackle.Hub.Forge.review_comment/0` expects."
  @type comment :: %{
          required(:path) => String.t(),
          required(:side) => :new | :old,
          required(:line) => pos_integer(),
          optional(:start_line) => pos_integer(),
          required(:body) => String.t()
        }

  @typedoc "A review to post and the fingerprints it posts in full."
  @type t :: %{body: String.t(), comments: [comment()], fingerprints: [String.t()]}

  @doc """
  Builds the review for `run` of `request` from its `findings`.

    * `request` - a map with the `:profile` the review used;
    * `run` - a map with `:id`, `:verdict`, and `:summary` (atom or string
      keys, as stored); `summary` gives the number of `units` reviewed;
    * `findings` - `Tackle.Hub.Reviews.Finding`s or maps with the same
      fields; only those with `state: :shown` are posted;
    * `files` - the pull request's files from the forge's current diff, or
      `[]` to put every finding in the body;
    * `known` - fingerprints already posted on the pull request, mentioned
      as still present instead of posted again.

  Raises `ArgumentError` when the run id cannot form a safe marker.
  """
  @spec build(map(), map(), [map()], [file()], MapSet.t(String.t())) :: t()
  def build(request, run, findings, files, %MapSet{} = known)
      when is_map(request) and is_map(run) and is_list(findings) and is_list(files) do
    marker = review_marker!(Map.get(run, :id))
    {findings, invalid} = prepare(findings)
    {old, new} = Enum.split_with(findings, &MapSet.member?(known, &1.fingerprint))
    {placed, unplaced} = place(new, index(files))
    {commented, overflow} = Enum.split(placed, @max_comments)

    comments =
      Enum.map(commented, fn {finding, location} ->
        Map.put(location, :body, IO.iodata_to_binary(entry(finding, nil)))
      end)

    listed = sort(Enum.map(overflow, &elem(&1, 0)) ++ unplaced)

    counts = %{
      findings: findings,
      comments: length(comments),
      overflow: length(overflow),
      invalid: invalid,
      known: length(old)
    }

    {body, posted} = body(marker, request, run, counts, listed, old)

    %{
      body: body,
      comments: comments,
      fingerprints: Enum.map(commented, fn {finding, _} -> finding.fingerprint end) ++ posted
    }
  end

  @doc """
  The lines of a unified diff patch that can carry a comment, by hunk.

  Each hunk gives the line numbers it shows on the old side (removed and
  context lines) and on the new side (added and context lines). Text
  before the first `@@` header is skipped; parsing stops at the first
  malformed or truncated hunk (too few lines for its counts, a line of
  the wrong kind, or one that is neither a header nor the end after it),
  keeping the complete hunks before it.
  `nil` (no patch) has no lines.
  """
  @spec hunks(String.t() | nil) :: [%{old: Range.t(), new: Range.t()}]
  def hunks(nil), do: []

  def hunks(patch) when is_binary(patch) do
    patch
    |> String.split("\n")
    |> drop_final_empty()
    |> Enum.drop_while(&(not String.starts_with?(&1, "@@")))
    |> parse_hunks([])
  end

  def hunks(_patch), do: []

  ## Findings

  defp prepare(findings) do
    {valid, invalid} =
      findings
      |> Enum.filter(&(is_map(&1) and Map.get(&1, :state) == :shown))
      |> Enum.map(&normalize/1)
      |> Enum.split_with(&valid_fingerprint?(&1.fingerprint))

    {valid |> sort() |> Enum.uniq_by(& &1.fingerprint), length(invalid)}
  end

  defp normalize(finding) do
    %{
      fingerprint: Map.get(finding, :fingerprint),
      blocking: Map.get(finding, :blocking) == true,
      severity: known(Map.get(finding, :severity), @severities),
      category: known(Map.get(finding, :category), @categories),
      title: string(Map.get(finding, :title)),
      body: string(Map.get(finding, :body)),
      trigger: string(Map.get(finding, :trigger)),
      suggestion: string(Map.get(finding, :suggestion)),
      path: string(Map.get(finding, :path)),
      side: known(Map.get(finding, :side), [:new, :old]),
      start_line: line(Map.get(finding, :start_line)),
      end_line: line(Map.get(finding, :end_line))
    }
  end

  defp known(value, allowed), do: if(value in allowed, do: value)
  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil
  defp line(value) when is_integer(value) and value > 0, do: value
  defp line(_value), do: nil

  defp valid_fingerprint?(value), do: is_binary(value) and Regex.match?(@fingerprint, value)

  # Enum.sort_by/2 is stable: the stored order (best first) breaks ties.
  defp sort(findings), do: Enum.sort_by(findings, &{not &1.blocking, severity_rank(&1.severity)})

  defp severity_rank(severity),
    do: Enum.find_index(@severities, &(&1 == severity)) || length(@severities)

  ## Placement

  defp index(files) do
    Enum.reduce(files, %{}, fn
      %{path: path} = file, acc when is_binary(path) ->
        Map.put_new_lazy(acc, path, fn -> hunks(Map.get(file, :patch)) end)

      _file, acc ->
        acc
    end)
  end

  defp place(findings, index) do
    Enum.reduce(findings, {[], []}, fn finding, {placed, unplaced} ->
      case locate(finding, index) do
        {:ok, location} -> {[{finding, location} | placed], unplaced}
        :error -> {placed, [finding | unplaced]}
      end
    end)
    |> then(fn {placed, unplaced} -> {Enum.reverse(placed), Enum.reverse(unplaced)} end)
  end

  defp locate(%{path: path, side: side, end_line: line} = finding, index)
       when is_binary(path) and side in [:new, :old] and is_integer(line) do
    with {:ok, hunks} <- Map.fetch(index, path),
         %{} = hunk <- Enum.find(hunks, &(line in Map.fetch!(&1, side))) do
      start = finding.start_line
      location = %{path: path, side: side, line: line}

      if is_integer(start) and start < line and start in Map.fetch!(hunk, side),
        do: {:ok, Map.put(location, :start_line, start)},
        else: {:ok, location}
    else
      _ -> :error
    end
  end

  defp locate(_finding, _index), do: :error

  ## Diff hunks

  defp drop_final_empty(lines) do
    case List.last(lines) do
      "" -> Enum.drop(lines, -1)
      _ -> lines
    end
  end

  defp parse_hunks([], acc), do: Enum.reverse(acc)

  # A hunk counts only when the line after it is another header or the end:
  # anything else means the counts, and so the hunk's lines, are wrong.
  defp parse_hunks([header | rest], acc) do
    with {:ok, hunk, old_count, new_count} <- header(header),
         {:ok, rest} <- hunk_body(rest, old_count, new_count),
         true <- rest == [] or String.starts_with?(hd(rest), "@@") do
      parse_hunks(rest, [hunk | acc])
    else
      _malformed -> Enum.reverse(acc)
    end
  end

  defp header(line) do
    case Regex.run(@hunk_header, line, capture: :all_but_first) do
      nil ->
        :error

      captures ->
        [old_start, old_count, new_start, new_count] =
          captures |> pad(4) |> Enum.map(&count/1)

        old_count = old_count || 1
        new_count = new_count || 1

        if (old_count > 0 and old_start == 0) or (new_count > 0 and new_start == 0) do
          :error
        else
          hunk = %{
            old: old_start..(old_start + old_count - 1)//1,
            new: new_start..(new_start + new_count - 1)//1
          }

          {:ok, hunk, old_count, new_count}
        end
    end
  end

  defp pad(list, size), do: list ++ List.duplicate("", size - length(list))
  defp count(""), do: nil
  defp count(digits), do: String.to_integer(digits)

  # Consumes exactly the lines the header counts; "\ No newline at end of
  # file" notes do not count. Too few lines (a truncated patch) or a line of
  # the wrong kind makes the hunk malformed.
  defp hunk_body(["\\" <> _ | rest], old, new), do: hunk_body(rest, old, new)
  defp hunk_body(lines, 0, 0), do: {:ok, lines}

  defp hunk_body([" " <> _ | rest], old, new) when old > 0 and new > 0,
    do: hunk_body(rest, old - 1, new - 1)

  defp hunk_body(["-" <> _ | rest], old, new) when old > 0, do: hunk_body(rest, old - 1, new)
  defp hunk_body(["+" <> _ | rest], old, new) when new > 0, do: hunk_body(rest, old, new - 1)
  defp hunk_body(_lines, _old, _new), do: :error

  ## Body

  defp body(marker, request, run, counts, listed, old) do
    entries =
      Enum.map(listed, fn finding ->
        heading =
          if finding.blocking, do: "#### Blocking findings", else: "#### Optional findings"

        {heading, "\n\n", IO.iodata_to_binary(entry(finding, :location)), finding.fingerprint}
      end) ++
        Enum.map(old, fn finding ->
          {"#### Still present from an earlier review", "\n", still_present(finding), nil}
        end)

    header = IO.iodata_to_binary(header(marker, request, run, counts))

    acc = %{
      parts: [header],
      size: byte_size(header),
      heading: nil,
      posted: [],
      cut: 0,
      cut_old: 0
    }

    acc = Enum.reduce(entries, acc, &add_entry/2)

    body = IO.iodata_to_binary([Enum.reverse(acc.parts), cut_notice(acc)])
    {body, Enum.reverse(acc.posted)}
  end

  defp add_entry({_heading, _sep, _text, fingerprint}, %{cut: cut, cut_old: cut_old} = acc)
       when cut > 0 or cut_old > 0,
       do: count_cut(acc, fingerprint)

  defp add_entry({heading, separator, text, fingerprint}, acc) do
    piece =
      if heading == acc.heading,
        do: [separator, text],
        else: ["\n\n", heading, "\n\n", text]

    size = acc.size + IO.iodata_length(piece)

    cond do
      size + @notice_reserve > @max_body_bytes ->
        count_cut(acc, fingerprint)

      fingerprint == nil ->
        %{acc | parts: [piece | acc.parts], size: size, heading: heading}

      true ->
        %{acc | parts: [piece | acc.parts], size: size, heading: heading}
        |> Map.update!(:posted, &[fingerprint | &1])
    end
  end

  defp count_cut(acc, nil), do: Map.update!(acc, :cut_old, &(&1 + 1))
  defp count_cut(acc, _fingerprint), do: Map.update!(acc, :cut, &(&1 + 1))

  defp cut_notice(%{cut: 0, cut_old: 0}), do: []

  defp cut_notice(%{cut: cut, cut_old: cut_old}) do
    parts =
      [
        cut > 0 && plural(cut, "finding"),
        cut_old > 0 && plural(cut_old, "earlier finding") <> " still present"
      ]
      |> Enum.filter(& &1)
      |> Enum.join(" and ")

    ["\n\n**Truncated:** ", parts, " left out to keep this review within the size limit."]
  end

  defp header(marker, request, run, counts) do
    blocking = Enum.count(counts.findings, & &1.blocking)
    optional = length(counts.findings) - blocking

    verdict =
      Map.get(@verdicts, Map.get(run, :verdict), "finished")

    [
      marker,
      "\n**Tackle review: ",
      verdict,
      "**\n\n",
      totals(blocking, optional, counts),
      reviewed(request, run),
      notes(counts)
    ]
  end

  defp totals(0, 0, _counts), do: "No findings."

  defp totals(blocking, optional, counts) do
    placement =
      [
        counts.comments > 0 && "#{counts.comments} as line comments",
        length(counts.findings) - counts.comments - counts.known > 0 &&
          "#{length(counts.findings) - counts.comments - counts.known} below",
        counts.known > 0 && "#{counts.known} already reported"
      ]
      |> Enum.filter(& &1)
      |> Enum.join(", ")

    "#{plural(blocking + optional, "finding")} (#{blocking} blocking, #{optional} optional): " <>
      placement <> "."
  end

  defp reviewed(request, run) do
    case {profile_text(Map.get(request, :profile)), units_text(Map.get(run, :summary))} do
      {nil, nil} -> []
      {profile, nil} -> ["\nReviewed with ", profile, "."]
      {nil, units} -> ["\n", String.capitalize(units), "."]
      {profile, units} -> ["\n", String.capitalize(units), " with ", profile, "."]
    end
  end

  # Only known profile names reach the text.
  defp profile_text(profile) do
    case Enum.find(Rank.profiles(), &(&1 == profile or Atom.to_string(&1) == profile)) do
      nil -> nil
      name -> "the #{name} profile"
    end
  end

  # Stored summaries have string keys; a summary in memory has atoms.
  defp units_text(summary) when is_map(summary) do
    case Map.get(summary, :units, Map.get(summary, "units")) do
      units when is_integer(units) and units >= 0 -> "#{plural(units, "unit")} reviewed"
      _units -> nil
    end
  end

  defp units_text(_summary), do: nil

  defp notes(counts) do
    [
      counts.overflow > 0 &&
        "\n\nLine comments are limited to #{@max_comments}; " <>
          "#{plural(counts.overflow, "more finding")} on diff lines #{verb(counts.overflow)} listed below.",
      counts.invalid > 0 &&
        "\n\n#{plural(counts.invalid, "finding")} without a valid fingerprint " <>
          "#{verb(counts.invalid)} left out."
    ]
    |> Enum.filter(& &1)
  end

  defp plural(1, noun), do: "1 " <> noun
  defp plural(n, noun), do: "#{n} #{noun}s"
  defp verb(1), do: "is"
  defp verb(_n), do: "are"

  ## Entries

  # A finding's text, as a line comment (`nil`) or a body entry with its
  # location. Every model-written field goes through prose/1 or code.
  defp entry(finding, location) do
    [
      finding_marker(finding.fingerprint),
      "\n**",
      label(finding),
      ":** ",
      title(finding.title, @max_title),
      if(location, do: ["\n", location(finding)], else: []),
      section(nil, finding.body, @max_text),
      section("Fails when:", finding.trigger, @max_trigger),
      suggestion(finding.suggestion)
    ]
  end

  defp still_present(finding) do
    [
      "- **",
      if(finding.blocking, do: "Blocking", else: "Optional"),
      ":** ",
      title(finding.title, @max_list_title),
      " (",
      code_span(finding.fingerprint),
      ")"
    ]
    |> IO.iodata_to_binary()
  end

  defp label(finding) do
    [if(finding.blocking, do: "Blocking", else: "Optional"), finding.severity, finding.category]
    |> Enum.filter(& &1)
    |> Enum.map_join(" · ", &to_string/1)
  end

  defp title(text, max) do
    case prose(single_line(text), max) do
      "" -> "(untitled)"
      title -> title
    end
  end

  defp location(%{path: nil}), do: "Location unknown."

  defp location(finding) do
    lines =
      case finding do
        %{start_line: start, end_line: last}
        when is_integer(start) and is_integer(last) and start < last ->
          ", lines #{start}–#{last}"

        %{end_line: last} when is_integer(last) ->
          ", line #{last}"

        _finding ->
          ""
      end

    side = if finding.side == :old, do: " (old side)", else: ""
    ["In ", code_span(single_line(finding.path)), lines, side, "."]
  end

  defp section(_label, nil, _max), do: []

  defp section(label, text, max) do
    case prose(text, max) do
      "" -> []
      text when label == nil -> ["\n\n", text]
      text -> ["\n\n**", label, "** ", text]
    end
  end

  defp suggestion(nil), do: []

  defp suggestion(text) do
    {code, truncated?} = text |> clean(:code) |> cap(@max_suggestion)

    case code |> code() |> String.trim_trailing("\n") do
      "" ->
        []

      code ->
        fence = String.duplicate("`", max(3, longest_run(code) + 1))
        note = if truncated?, do: "\n\n*(suggestion truncated)*", else: []
        ["\n\n**Suggestion:**\n\n", fence, "\n", code, "\n", fence, note]
    end
  end

  defp code_span(text) do
    code = text |> clean(:code) |> single_line() |> code()
    fence = String.duplicate("`", longest_run(code) + 1)

    cond do
      code == "" ->
        "(empty)"

      String.starts_with?(code, ["`", " "]) or String.ends_with?(code, ["`", " "]) ->
        [fence, " ", code, " ", fence]

      true ->
        [fence, code, fence]
    end
  end

  defp longest_run(text) do
    ~r/`+|~+/
    |> Regex.scan(text)
    |> Enum.map(fn [run] -> byte_size(run) end)
    |> Enum.max(fn -> 0 end)
  end

  defp single_line(nil), do: ""
  defp single_line(text), do: String.replace(text, ~r/[\r\n]+/, " ")

  ## Markers

  defp review_marker!(id) do
    if is_binary(id) and Regex.match?(@run_id, id),
      do: "<!-- tackle-review:" <> id <> " -->",
      else: raise(ArgumentError, "run id cannot form a review marker: #{inspect(id)}")
  end

  defp finding_marker(fingerprint), do: "<!-- tackle-finding:" <> fingerprint <> " -->"

  ## Sanitizing

  # Untrusted text as plain prose: no HTML, Markdown syntax, entities,
  # mentions, issue references, URLs, or closing keywords survive.
  defp prose(text, max) do
    {text, truncated?} = text |> clean(:prose) |> cap(max)

    text =
      text
      |> String.replace(@prose_keyword, &break_word/1)
      |> String.replace(~r/#(?=\d)/u, "#" <> @zwsp)
      |> String.replace(~r/(?<![A-Za-z0-9])(GH-)(?=\d)/iu, "\\1" <> @zwsp)
      |> String.replace("://", ":" <> @zwsp <> "//")
      |> String.replace(~r/(?<![A-Za-z0-9])(www)\./iu, "\\1" <> @zwsp <> ".")
      |> escape()
      |> String.replace(~r/[ \t]+\n/, "\n")
      |> String.replace(~r/\n{3,}/, "\n\n")
      |> String.trim()

    if truncated? and text != "", do: text <> " *(truncated)*", else: text
  end

  defp escape(text) do
    for <<char::utf8 <- text>>, into: "", do: escape_char(char)
  end

  defp escape_char(?&), do: "&amp;"
  defp escape_char(?<), do: "&lt;"
  defp escape_char(?>), do: "&gt;"
  defp escape_char(?"), do: "&quot;"
  defp escape_char(?'), do: "&#39;"
  defp escape_char(?@), do: "@" <> @zwsp
  # Fullwidth and small commercial at.
  defp escape_char(char) when char in [0xFF20, 0xFE6B], do: <<char::utf8>> <> @zwsp
  defp escape_char(char) when char in @markdown, do: <<?\\, char>>
  defp escape_char(char), do: <<char::utf8>>

  # Code keeps its characters; only what could act outside the fence, or be
  # read as a marker or mention, gets a zero-width space.
  defp code(text) do
    text
    |> String.replace("<!--", "<" <> @zwsp <> "!--")
    |> String.replace(~r/([@\x{FF20}\x{FE6B}])(?=[\p{L}\p{N}_])/u, "\\1" <> @zwsp)
    |> String.replace(@code_keyword, &break_word/1)
  end

  defp break_word(<<first::utf8, rest::binary>>), do: <<first::utf8>> <> @zwsp <> rest

  # Invalid UTF-8 is replaced; line breaks are normalized; control,
  # invisible format (zero-width, bidi), private-use, and line/paragraph
  # separator characters are removed. Prose turns tabs into spaces.
  defp clean(text, mode) do
    text
    |> String.replace_invalid()
    |> String.replace(~r/\r\n?|[\x{2028}\x{2029}]/u, "\n")
    |> then(&if(mode == :prose, do: String.replace(&1, "\t", " "), else: &1))
    |> String.replace(~r/(?![\n\t])[\p{Cc}\p{Cf}\p{Co}]/u, "")
  end

  # Caps by code points, not graphemes: one grapheme can hold any number
  # of combining marks.
  defp cap(text, max) do
    chars = String.to_charlist(text)

    if length(chars) <= max,
      do: {text, false},
      else: {chars |> Enum.take(max) |> List.to_string(), true}
  end
end
