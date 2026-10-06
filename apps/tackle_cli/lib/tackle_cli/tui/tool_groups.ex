defmodule Tackle.CLI.TUI.ToolGroups do
  @moduledoc """
  Classifies read-only tool calls and collapses consecutive ones into one card.

  Ported from Codex's TUI activity groups (`exec_cell/model.rs` and
  `chatwidget/activity_groups.rs`): a run of adjacent "exploring" calls —
  file reads, directory listings, searches — renders as a single summary cell
  so long turns stay scannable, while every full command and its output stay
  available in details.

  `read` calls are exploring by definition. `bash` commands are classified
  with a small POSIX-ish tokenizer and the same command heuristics as Codex's
  `parse_command`: `cat`/`sed -n`/`head` are reads, `ls`/`find`/`tree` are
  listings, `grep`/`rg` are searches. A command with any unrecognized segment —
  including every mutating command — is not exploring, so writes never
  collapse. Wrapper segments that never summarize on their own (`cd`, `echo`,
  `true`, and pipeline formatters like `wc`) are dropped, so `cd lib && cat
  a.ex` is a read.

  Codex groups at event ingestion and later repairs groups split by transport
  pages. Tackle re-projects its transcript on every refresh, so grouping
  happens here at projection time: consecutive exploring entries become one
  group entry and no repair pass is needed. Classification is a local,
  best-effort summary for display; it never changes what the tool actually did.
  """

  alias Tackle.CLI.TUI.{MessageView, ToolView}

  @typedoc "One classified command segment."
  @type action ::
          {:read, String.t()}
          | {:list, String.t() | nil}
          | {:search, String.t() | nil, String.t() | nil}

  @typedoc "One rendered summary row; consecutive completed reads share a row."
  @type summary_row :: %{
          kind: :read | :list | :search,
          names: [String.t()] | nil,
          path: String.t() | nil,
          query: String.t() | nil,
          failed?: boolean(),
          error: String.t() | nil
        }

  @connectors ["&&", "||", "|", ";"]
  # Segments that never summarize on their own but wrap a real command.
  @dropped_heads ["cd", "true", "echo"]
  # Read-only pipeline tail helpers: `cat x | wc -l` is still a read.
  @formatting_heads ["wc", "nl", "sort", "uniq", "tr", "cut", "awk", "column", "tac", "rev"]

  @ls_flags ["-I", "-w", "--block-size", "--format", "--time-style", "--color", "--quoting-style"]
  @tree_flags ["-L", "-P", "-I", "--charset", "--filelimit", "--sort"]
  @du_flags ["-d", "--max-depth", "-B", "--block-size", "--exclude", "--time-style"]
  @rg_flags [
    "-g",
    "--glob",
    "--iglob",
    "-t",
    "--type",
    "--type-add",
    "--type-not",
    "-m",
    "--max-count",
    "-A",
    "-B",
    "-C",
    "--context",
    "--max-depth",
    "--max-filesize"
  ]
  @grep_flags [
    "-e",
    "--regexp",
    "-A",
    "-B",
    "-C",
    "--context",
    "-m",
    "--max-count",
    "--include",
    "--exclude",
    "--exclude-dir",
    "--color",
    "--colour"
  ]
  @ag_flags [
    "-G",
    "-g",
    "--file-search-regex",
    "--ignore-dir",
    "--ignore-file",
    "--path-to-ignore"
  ]
  @fd_flags ["-t", "--type", "-e", "--extension", "-E", "--exclude", "--search-path"]
  @bat_flags [
    "--theme",
    "--language",
    "--style",
    "--terminal-width",
    "--tabs",
    "--line-range",
    "--map-syntax"
  ]
  @less_flags [
    "-p",
    "-P",
    "-x",
    "-y",
    "-z",
    "-j",
    "--pattern",
    "--prompt",
    "--tabs",
    "--shift",
    "--jump-target"
  ]
  @head_tail_flags ["-n", "--lines", "-c", "--bytes"]
  @sed_flags ["-e", "--expression", "-f", "--file"]
  @sed_range ~r/\A\d+(,\d+)?p\z/

  @doc """
  Classifies one tool entry into summary actions, or `:unknown`.

  Only `read` and `bash` calls classify. A compound command classifies only
  when every segment does, so one mutating segment disqualifies the call.
  """
  @spec classify(map()) :: [action()] | :unknown
  def classify(%{kind: :tool, tool_group: group}) when is_list(group) and group != [],
    do: :unknown

  def classify(%{kind: :tool, tool_name: "read"} = entry) do
    case ToolView.arguments(entry.tool_arguments) |> fetch(:path) do
      path when is_binary(path) and path != "" -> [{:read, short_path(path)}]
      _ -> :unknown
    end
  end

  def classify(%{kind: :tool, tool_name: "bash"} = entry) do
    case ToolView.arguments(entry.tool_arguments) |> fetch(:command) do
      command when is_binary(command) and command != "" -> classify_script(command)
      _ -> :unknown
    end
  end

  def classify(_entry), do: :unknown

  @doc "Returns whether an entry is an exploring call that may join a group."
  @spec exploring?(map()) :: boolean()
  def exploring?(%{kind: :tool} = entry) do
    case classify(entry) do
      [_ | _] -> true
      _ -> false
    end
  end

  def exploring?(_entry), do: false

  @doc """
  Collapses runs of consecutive exploring entries into single group entries.

  Runs with fewer than two tool calls stay alone: a lone read keeps its normal
  card. Collapsed thinking after an exploring call stays inside the group as
  retained detail, matching Codex's hidden reasoning handling. Prose, expanded
  thinking, and non-exploring tools end a run.
  """
  @spec group([MessageView.t()]) :: [MessageView.t()]
  def group([]), do: []

  def group([entry | rest]) do
    if exploring?(entry) do
      {run, rest} = Enum.split_while(rest, &(exploring?(&1) or hidden_thinking?(&1)))
      members = [entry | run]

      grouped =
        if Enum.count(members, &exploring?/1) > 1,
          do: [MessageView.tool_group_entry(members)],
          else: members

      grouped ++ group(rest)
    else
      [entry | group(rest)]
    end
  end

  defp hidden_thinking?(%{kind: :thinking, collapsed?: true}), do: true
  defp hidden_thinking?(_entry), do: false

  @doc """
  Builds the summary rows for a group's members.

  Consecutive completed reads merge into one row of unique names, as in
  Codex's exploring display. Failed calls keep their own row plus the first
  line of their error, so failures stay visible inside the collapsed card.
  """
  @spec rows([map()]) :: [summary_row()]
  def rows(members) do
    members
    |> Enum.flat_map(fn member ->
      case classify(member) do
        :unknown ->
          []

        actions ->
          failed? = member.tool_status == :failed
          error = if failed?, do: error_line(member)

          actions
          |> Enum.with_index()
          |> Enum.map(fn {action, index} ->
            {action, failed?, if(index == length(actions) - 1, do: error)}
          end)
      end
    end)
    |> merge_reads([])
  end

  # The first non-empty retained line, bounded so one failing call cannot
  # rebuild a wall of output inside the collapsed card.
  defp error_line(member) do
    case member.tool_output do
      output when is_binary(output) ->
        output
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.at(0)
        |> case do
          nil -> nil
          line -> String.slice(line, 0, 160)
        end

      _ ->
        nil
    end
  end

  ## Script classification

  defp classify_script(script) do
    results =
      script
      |> String.split("\n")
      |> Enum.reject(&(comment?(&1) or String.trim(&1) == ""))
      |> Enum.map(&line_actions/1)

    if results == [] or :unknown in results do
      :unknown
    else
      results |> List.flatten() |> dedup()
    end
  end

  defp comment?(line), do: line |> String.trim_leading() |> String.starts_with?("#")

  defp line_actions(line) do
    actions =
      line
      |> tokenize()
      |> unwrap_shell()
      |> split_connectors()
      |> drop_wrappers()
      |> Enum.map(&summarize/1)

    if actions == [] or :unknown in actions, do: :unknown, else: actions
  end

  # Collapse consecutive identical actions so repeated reads summarize once.
  defp dedup(actions) do
    actions
    |> Enum.reduce([], fn
      action, [action | _] = acc -> acc
      action, acc -> [action | acc]
    end)
    |> Enum.reverse()
  end

  defp unwrap_shell([shell, flag, script])
       when shell in ["bash", "sh", "zsh", "dash"] and flag in ["-c", "-lc"] do
    script |> tokenize() |> unwrap_shell()
  end

  defp unwrap_shell(tokens), do: tokens

  defp split_connectors(tokens) do
    tokens
    |> Enum.reduce({[], []}, fn token, {segments, current} ->
      if token in @connectors,
        do: {flush_segment(segments, current), []},
        else: {segments, [token | current]}
    end)
    |> then(fn {segments, current} -> flush_segment(segments, current) end)
    |> Enum.reverse()
  end

  defp flush_segment(segments, []), do: segments
  defp flush_segment(segments, current), do: [Enum.reverse(current) | segments]

  defp drop_wrappers(segments) do
    Enum.reject(segments, fn
      [] ->
        true

      [head | tail] ->
        head in @dropped_heads or head in @formatting_heads or
          (head in ["head", "tail"] and operands(tail, @head_tail_flags) == [])
    end)
  end

  ## Per-segment summaries

  defp summarize([head | tail]) do
    case head do
      head when head in ["ls", "eza", "exa"] -> {:list, operand(tail, @ls_flags)}
      "tree" -> {:list, operand(tail, @tree_flags)}
      "du" -> {:list, operand(tail, @du_flags)}
      "pwd" -> {:list, nil}
      head when head in ["rg", "rga"] -> summarize_rg(tail)
      head when head in ["grep", "egrep", "fgrep"] -> search_operands(tail, @grep_flags)
      head when head in ["ag", "ack", "pt"] -> search_operands(tail, @ag_flags)
      "git" -> summarize_git(tail)
      "find" -> summarize_find(tail)
      "fd" -> summarize_fd(tail)
      "cat" -> read_operand(tail, [])
      head when head in ["bat", "batcat"] -> read_operand(tail, @bat_flags)
      "less" -> read_operand(tail, @less_flags)
      "more" -> read_operand(tail, [])
      head when head in ["head", "tail"] -> read_operand(tail, @head_tail_flags)
      "sed" -> summarize_sed(tail)
      _ -> :unknown
    end
  end

  defp summarize([]), do: :unknown

  defp read_operand(args, flags) do
    case operands(args, flags) do
      [path] -> {:read, short_path(path)}
      _ -> :unknown
    end
  end

  defp search_operands(args, flags) do
    case operands(args, flags) do
      [query] -> {:search, query, nil}
      [query, path | _] -> {:search, query, short_path(path)}
      _ -> :unknown
    end
  end

  defp summarize_rg(args) do
    if "--files" in args do
      path =
        case operands(args, @rg_flags) do
          [path | _] -> short_path(path)
          _ -> nil
        end

      {:list, path}
    else
      search_operands(args, @rg_flags)
    end
  end

  defp summarize_git(["grep" | tail]), do: search_operands(tail, @grep_flags)

  defp summarize_git(["ls-files" | tail]) do
    path =
      case operands(tail, ["--exclude", "--exclude-from", "--pathspec-from-file"]) do
        [path | _] -> short_path(path)
        _ -> nil
      end

    {:list, path}
  end

  defp summarize_git(_tail), do: :unknown

  defp summarize_find(args) do
    path = Enum.find(args, &(not String.starts_with?(&1, "-") and &1 not in ["!", "(", ")"]))
    query = flag_value(args, ["-name", "-iname", "-path", "-regex"])

    if query,
      do: {:search, query, path && short_path(path)},
      else: {:list, path && short_path(path)}
  end

  defp summarize_fd(args) do
    case operands(args, @fd_flags) do
      [one] ->
        if pathish?(one), do: {:list, short_path(one)}, else: {:search, one, nil}

      [query, path | _] ->
        {:search, query, short_path(path)}

      _ ->
        {:list, nil}
    end
  end

  defp summarize_sed(args) do
    cond do
      "-n" not in args -> :unknown
      Enum.any?(args, &String.starts_with?(&1, "-i")) -> :unknown
      not sed_range?(args) -> :unknown
      true -> sed_read(args)
    end
  end

  # `sed -n 12,40p mix.exs` reads one bounded range of one file.
  defp sed_range?(args) do
    Enum.any?(args, &Regex.match?(@sed_range, &1)) or
      case flag_value(args, ["-e", "--expression"]) do
        value when is_binary(value) -> Regex.match?(@sed_range, value)
        _ -> false
      end
  end

  defp sed_read(args) do
    case operands(args, @sed_flags) do
      [first, path | _] ->
        if sed_range_arg?(first), do: {:read, short_path(path)}, else: :unknown

      [first] ->
        if sed_range_arg?(first), do: :unknown, else: {:read, short_path(first)}

      _ ->
        :unknown
    end
  end

  defp sed_range_arg?(arg), do: is_binary(arg) and Regex.match?(@sed_range, arg)

  ## Token and operand helpers

  # A small POSIX-ish tokenizer: whitespace splits, quotes group, and a
  # backslash escapes the next byte. It does not expand or substitute, and an
  # unclosed quote keeps the remainder as one token.
  defp tokenize(input), do: input |> tokenize([], "", nil) |> Enum.reverse()

  defp tokenize("", tokens, current, nil), do: flush_token(tokens, current)
  defp tokenize("", tokens, current, _quote), do: flush_token(tokens, current)

  defp tokenize(<<char, rest::binary>>, tokens, current, nil) do
    cond do
      char in [?\s, ?\t] -> tokenize(rest, flush_token(tokens, current), "", nil)
      char == ?' -> tokenize(rest, tokens, current, :single)
      char == ?" -> tokenize(rest, tokens, current, :double)
      char == ?\\ -> escape_next(rest, tokens, current, nil)
      char in [?;, ?&, ?|] -> tokenize_connector(char, rest, tokens, current)
      true -> tokenize(rest, tokens, <<current::binary, char>>, nil)
    end
  end

  defp tokenize(<<char, rest::binary>>, tokens, current, :single) do
    if char == ?',
      do: tokenize(rest, tokens, current, nil),
      else: tokenize(rest, tokens, <<current::binary, char>>, :single)
  end

  defp tokenize(<<char, rest::binary>>, tokens, current, :double) do
    cond do
      char == ?" -> tokenize(rest, tokens, current, nil)
      char == ?\\ -> escape_next(rest, tokens, current, :double)
      true -> tokenize(rest, tokens, <<current::binary, char>>, :double)
    end
  end

  defp escape_next(<<char, rest::binary>>, tokens, current, quote),
    do: tokenize(rest, tokens, <<current::binary, char>>, quote)

  defp escape_next("", tokens, current, _quote), do: flush_token(tokens, current)

  # Shell connectors are their own tokens even without surrounding spaces,
  # so `cat a&&ls` splits like `cat a && ls`.
  defp tokenize_connector(char, <<next, rest::binary>>, tokens, current)
       when (char == ?& and next == ?&) or (char == ?| and next == ?|),
       do: tokenize(rest, [<<char, next>> | flush_token(tokens, current)], "", nil)

  defp tokenize_connector(char, rest, tokens, current),
    do: tokenize(rest, [<<char>> | flush_token(tokens, current)], "", nil)

  defp flush_token(tokens, ""), do: tokens
  defp flush_token(tokens, current), do: [current | tokens]

  # Positional operands: skip flags, values of known value-taking flags, and
  # `--flag=value` forms; everything after `--` is an operand.
  defp operands(args, flags_with_vals) do
    args
    |> Enum.reduce({[], false}, fn
      _arg, {operands, :skip} ->
        {operands, false}

      arg, {operands, after_dash} ->
        cond do
          after_dash -> {[arg | operands], true}
          arg == "--" -> {operands, true}
          arg in flags_with_vals -> {operands, :skip}
          String.starts_with?(arg, "-") -> {operands, after_dash}
          true -> {[arg | operands], after_dash}
        end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp operand(args, flags) do
    case operands(args, flags) do
      [path | _] -> short_path(path)
      [] -> nil
    end
  end

  defp flag_value(args, flags) do
    case Enum.find_index(args, &(&1 in flags)) do
      nil -> nil
      index -> Enum.at(args, index + 1)
    end
  end

  defp pathish?(value),
    do:
      value in [".", ".."] or String.starts_with?(value, ["./", "../"]) or
        String.contains?(value, "/")

  # Codex's short display path: the last component, skipping generated
  # directory names, so `packages/app/src` reads as `app`.
  defp short_path(path) do
    parts =
      path
      |> String.replace("\\", "/")
      |> String.trim_trailing("/")
      |> String.split("/")
      |> Enum.reverse()
      |> Enum.reject(&(&1 in ["", "build", "dist", "node_modules", "src"]))

    case parts do
      [name | _] -> name
      [] -> path
    end
  end

  defp fetch(args, key) when is_map(args),
    do: Map.get(args, key, Map.get(args, Atom.to_string(key)))

  defp fetch(_args, _key), do: nil

  ## Summary row merging

  defp merge_reads([], acc), do: Enum.reverse(acc)

  defp merge_reads([{{:read, name}, false, nil} | rest], acc) do
    {names, rest} = take_reads(rest, [name])

    merge_reads(rest, [
      %{kind: :read, names: names, path: nil, query: nil, failed?: false, error: nil} | acc
    ])
  end

  defp merge_reads([{{:read, name}, failed?, error} | rest], acc),
    do:
      merge_reads(
        rest,
        [
          %{kind: :read, names: [name], path: nil, query: nil, failed?: failed?, error: error}
          | acc
        ]
      )

  defp merge_reads([{{:list, path}, failed?, error} | rest], acc),
    do:
      merge_reads(rest, [
        %{kind: :list, names: nil, path: path, query: nil, failed?: failed?, error: error} | acc
      ])

  defp merge_reads([{{:search, query, path}, failed?, error} | rest], acc),
    do:
      merge_reads(
        rest,
        [
          %{kind: :search, names: nil, path: path, query: query, failed?: failed?, error: error}
          | acc
        ]
      )

  defp take_reads([{{:read, name}, false, nil} | rest], names),
    do: take_reads(rest, [name | names])

  defp take_reads(rest, names), do: {Enum.uniq(Enum.reverse(names)), rest}
end
