defmodule Tackle.CLI.TUI.FileSearch do
  @moduledoc """
  `@` file mentions with an asynchronous fuzzy workspace search.

  Typing `@` in the composer opens a completion popup anchored above the input
  bar, in the spirit of the Codex TUI's file-search popup. Every keystroke
  re-reads the token under the caret (`token/2`); while the token starts with
  `@` and is preceded by whitespace, the popup shows the workspace files that
  fuzzily match the query. `↑`/`↓` (or Ctrl+P/Ctrl+N) move the selection,
  Enter or Tab replaces the whole token with the selected file's full
  workspace-relative path, and Esc dismisses the popup for that token without
  touching the draft. Enter with nothing selected submits the draft as usual.

  The workspace file index is built once, off the render loop, by a bounded
  `Command.async` walk (`index/1`): hidden directories, symlinks, and the usual
  build/dependency directories are skipped, and both the directory and file
  counts are capped so a hostile or huge workspace cannot stall the shell. The
  index is cached in the shell state and reused across mentions; only the first
  `@` pays for the walk, and the popup says it is searching until the index
  lands.

  Filtering ranks an exact substring above a scattered subsequence, then by
  match position and path length, mirroring `Tackle.CLI.TUI.Picker`'s ranking.
  The subsequence pass only runs when too few substring matches exist, so a
  keystroke stays cheap even over a large index.

  This module never pattern-matches the shell state struct: `Tackle.CLI.TUI.State`
  embeds a `%__MODULE__{}` as its default, so the dependency must stay one-way.
  """

  alias ExRatatui.Command
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.List, as: SelectionList
  alias ExRatatui.Widgets.Paragraph
  alias Tackle.CLI.TUI.{CompletionPopup, History, Theme, Util, Viewport}
  alias Tackle.CLI.Widgets.Input
  alias Tackle.Executor

  require Logger

  @typedoc "One indexed file: `{downcased_path, path}`."
  @type entry :: {String.t(), String.t()}

  @typedoc "The cached workspace index and the token Esc has dismissed."
  @type t :: %__MODULE__{
          index: [entry()] | nil,
          index_ref: reference() | nil,
          dismissed: {non_neg_integer(), String.t()} | nil
        }

  @typedoc "View state for the open popup; `range` covers the whole `@token`."
  @type popup :: %{
          query: String.t(),
          range: {non_neg_integer(), non_neg_integer()},
          matches: [String.t()],
          selected: non_neg_integer(),
          waiting?: boolean()
        }

  # Bounds for the background walk. Symlinked directories are never followed,
  # so a loop cannot make the walk explode and a jailed workspace cannot leak
  # host paths through a planted symlink. The caps bound memory and walk time,
  # not safety; a walk that stops early is partial and says so in the log.
  @max_dirs 8_192
  @max_files 50_000

  # Rows shown in the popup, like Codex's MAX_POPUP_ROWS.
  @max_matches 8

  # Common build and dependency output; hidden directories are skipped wholesale.
  @skip_dirs ~w(deps _build node_modules target dist cover)

  defstruct index: nil, index_ref: nil, dismissed: nil

  # -- token detection ------------------------------------------------------

  @doc """
  Extracts the `@token` under the caret.

  Returns `{start, stop, query}` covering the whole token including the `@`,
  with `query` the text after it (possibly empty), or `nil` when the caret is
  not on a token that begins with `@`. A token is a whitespace-delimited run on
  the caret's line; the `@` must start the run, so text like an email address
  does not open the popup. Tokens never span lines.
  """
  @spec token(String.t(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer(), String.t()} | nil
  def token(draft, cursor) when is_binary(draft) and is_integer(cursor) and cursor >= 0 do
    cursor = Util.floor_boundary(draft, min(cursor, byte_size(draft)))
    line_start = line_start(draft, cursor)
    line_end = line_end(draft, cursor)
    line = binary_part(draft, line_start, line_end - line_start)

    {left, right} = token_bounds(line, cursor - line_start)

    if left < right do
      case binary_part(line, left, right - left) do
        "@" <> query ->
          if left == 0 or whitespace?(line, left - 1),
            do: {line_start + left, line_start + right, query}

        _other ->
          nil
      end
    end
  end

  defp line_start(draft, cursor) do
    prefix = binary_part(draft, 0, cursor)

    case :binary.matches(prefix, "\n") do
      [] -> 0
      matches -> elem(List.last(matches), 0) + 1
    end
  end

  defp line_end(draft, cursor) do
    case :binary.match(draft, "\n", scope: {cursor, byte_size(draft) - cursor}) do
      {position, _length} -> position
      :nomatch -> byte_size(draft)
    end
  end

  # The whitespace-delimited run containing `offset`: scan out to both
  # delimiters on the same line.
  defp token_bounds(line, offset) do
    {scan_left(line, offset), scan_right(line, offset, byte_size(line))}
  end

  defp scan_left(line, position) when position > 0 do
    if whitespace?(line, position - 1), do: position, else: scan_left(line, position - 1)
  end

  defp scan_left(_line, 0), do: 0

  defp scan_right(line, position, bytes) when position < bytes do
    if whitespace?(line, position), do: position, else: scan_right(line, position + 1, bytes)
  end

  defp scan_right(_line, bytes, bytes), do: bytes

  defp whitespace?(line, position) do
    case :binary.at(line, position) do
      byte when byte in [0x20, 0x09] -> true
      _other -> false
    end
  end

  # -- workspace index -----------------------------------------------------

  @doc """
  Builds the workspace file index for `root`, as relative paths.

  The walk is depth-first over alphabetically sorted entries, bounded to
  `@max_dirs` directories and `@max_files` files, and skips hidden
  directories, `@skip_dirs`, and every symlink. Entries are pre-downcased once
  so per-keystroke filtering only compares binaries. A walk that stops at a
  cap logs a warning, because its index is partial.
  """
  @spec index(Path.t()) :: [entry()]
  def index(root) when is_binary(root) do
    [{root, ""}]
    |> walk([], 0, 0, root)
    |> Enum.reverse()
    |> Enum.map(&{String.downcase(&1), &1})
  end

  defp walk([], found, _dirs, _files, _root), do: found

  defp walk([{dir, prefix} | rest], found, dirs, files, root)
       when dirs < @max_dirs and files < @max_files do
    case File.ls(dir) do
      {:ok, names} ->
        {found, files, children} =
          Enum.reduce(Enum.sort(names), {found, files, []}, fn name, {found, files, children} ->
            path = Path.join(dir, name)
            relative = if prefix == "", do: name, else: prefix <> "/" <> name

            case File.lstat(path) do
              {:ok, %File.Stat{type: :directory}} ->
                if visit_dir?(name),
                  do: {found, files, [{path, relative} | children]},
                  else: {found, files, children}

              {:ok, %File.Stat{type: :regular}} when files < @max_files ->
                {[relative | found], files + 1, children}

              _other ->
                {found, files, children}
            end
          end)

        # Children were collected by prepending, so restore the sorted order
        # before visiting: alphabetical depth-first keeps the index stable and
        # predictable instead of favoring whichever subtree sorts last.
        walk(Enum.reverse(children) ++ rest, found, dirs + 1, files, root)

      _error ->
        walk(rest, found, dirs, files, root)
    end
  end

  # A walk that stopped at a cap is partial; say so instead of silently
  # offering an index that looks complete.
  defp walk(_stack, found, dirs, files, root) do
    Logger.warning(
      "file-mention index for #{root} is partial: stopped after #{min(dirs, @max_dirs)} directories and #{min(files, @max_files)} files"
    )

    found
  end

  defp visit_dir?(name), do: not String.starts_with?(name, ".") and name not in @skip_dirs

  # -- filtering -----------------------------------------------------------

  @doc """
  Returns the paths matching `query`, best first, at most `@max_matches`.

  An empty query matches nothing: the popup shows its hint instead. Substring
  matches rank above scattered subsequences; within a tier an earlier, tighter
  match on a shorter path wins.
  """
  @spec filter([entry()], String.t()) :: [String.t()]
  def filter(_entries, query) when query in ["", nil], do: []

  def filter(entries, query) when is_list(entries) and is_binary(query) do
    needle = String.downcase(query)

    matches =
      for {down, path} <- entries, {position, _length} <- match_position(down, needle) do
        {substring_rank(position, down), path}
      end

    matches =
      if length(matches) >= @max_matches do
        matches
      else
        matches ++ subsequence_matches(entries, needle)
      end

    matches
    |> Enum.sort_by(fn {rank, _path} -> rank end)
    |> Enum.take(@max_matches)
    |> Enum.map(fn {_rank, path} -> path end)
  end

  defp substring_rank(position, down), do: {0, position, position, byte_size(down)}

  # A generator, so a non-matching entry is skipped instead of raising like a
  # filter's pattern match would.
  defp match_position(down, needle) do
    case :binary.match(down, needle) do
      {position, length} -> [{position, length}]
      :nomatch -> []
    end
  end

  # Only runs when the substring pass came up short, so the usual keystroke
  # never pays for scanning the whole index grapheme by grapheme.
  defp subsequence_matches(entries, needle) do
    for {down, path} <- entries,
        :binary.match(down, needle) == :nomatch,
        {first, last} <- subsequence_span(down, needle) do
      {{1, last - first, first, byte_size(down)}, path}
    end
  end

  defp subsequence_span(down, needle) do
    case subsequence(down, needle) do
      {first, last} -> [{first, last}]
      nil -> []
    end
  end

  # Byte-level subsequence over the pre-downcased text: every needle byte must
  # appear in order. Queries are ordinary file-name fragments, so this stays
  # cheap and correct for the ASCII that dominates paths.
  defp subsequence(down, needle) do
    scan(down, needle, 0, nil, nil)
  end

  defp scan(_down, <<>>, _from, nil, _last), do: nil
  defp scan(_down, <<>>, _from, first, last), do: {first, last}

  defp scan(down, <<byte, rest::binary>>, from, first, _last) do
    case :binary.match(down, <<byte>>, scope: {from, byte_size(down) - from}) do
      {position, _length} ->
        first = if is_nil(first), do: position, else: first
        scan(down, rest, position + 1, first, position)

      :nomatch ->
        nil
    end
  end

  # -- popup synchronization ------------------------------------------------

  @doc """
  Brings the popup in line with the draft after any edit.

  Opens or updates the `{:file_search, popup}` overlay while the caret is on an
  `@token` and the composer has the keyboard; closes it otherwise. Another
  overlay always wins: while a menu owns the screen the popup stays closed, and
  this function leaves that overlay untouched. Returns the commands to run,
  which is non-empty only when the workspace index has to be built.
  """
  @spec sync(Tackle.CLI.TUI.State.t()) :: {Tackle.CLI.TUI.State.t(), [Command.t()]}
  def sync(state) do
    cond do
      not manages?(state.overlay) -> {state, []}
      state.focus != :composer -> {close(state), []}
      true -> sync_token(state)
    end
  end

  defp sync_token(state) do
    case token(Input.get_value(state.input), Input.cursor(state.input)) do
      nil ->
        {close(state), []}

      {start, _stop, query} ->
        if state.file_search.dismissed == {start, query} do
          {close(state), []}
        else
          open(state, start, query)
        end
    end
  end

  defp manages?(nil), do: true
  defp manages?({:file_search, _popup}), do: true
  defp manages?(_other_overlay), do: false

  defp close(%{overlay: {:file_search, _popup}} = state), do: %{state | overlay: nil}
  defp close(state), do: state

  defp open(state, start, query) do
    {state, entries, commands} = ensure_index(state)

    {previous_query, previous_selected} =
      case state.overlay do
        {:file_search, popup} -> {popup.query, popup.selected}
        _other -> {nil, 0}
      end

    matches = if entries, do: filter(entries, query), else: []

    selected =
      if previous_query == query,
        do: min(previous_selected, max(length(matches) - 1, 0)),
        else: 0

    popup = %{
      query: query,
      range: {start, start + 1 + byte_size(query)},
      matches: matches,
      selected: selected,
      waiting?: is_nil(entries)
    }

    {%{state | overlay: {:file_search, popup}}, commands}
  end

  defp ensure_index(%{file_search: %{index: entries}} = state) when is_list(entries),
    do: {state, entries, []}

  defp ensure_index(%{file_search: %{index_ref: ref}} = state) when is_reference(ref),
    do: {state, nil, []}

  defp ensure_index(state) do
    root = Executor.workspace(state.executor) || File.cwd!()
    ref = make_ref()

    command =
      Command.async(fn -> index(root) end, &{:tui_file_index, ref, &1})

    state = %{state | file_search: %{state.file_search | index_ref: ref}}
    {state, nil, [command]}
  end

  @doc """
  Installs a finished workspace index and refreshes the open popup.

  Stale results (a newer walk, or no walk in flight) are dropped without a
  render. A failed walk becomes an empty index, so the popup reports that
  nothing matches rather than searching forever.
  """
  @spec apply_index(Tackle.CLI.TUI.State.t(), reference(), term()) ::
          {:noreply, Tackle.CLI.TUI.State.t()} | {:noreply, Tackle.CLI.TUI.State.t(), keyword()}
  def apply_index(%{file_search: %{index_ref: ref}} = state, ref, result) do
    state = %{
      state
      | file_search: %{state.file_search | index: normalize_index(result), index_ref: nil}
    }

    {state, commands} = sync(state)
    {:noreply, state, commands: commands}
  end

  def apply_index(state, _ref, _result), do: {:noreply, state, render?: false}

  defp normalize_index(entries) when is_list(entries), do: entries
  defp normalize_index(_other), do: []

  # -- popup keys -----------------------------------------------------------

  @doc """
  Handles one resolved file-popup intent.

  `↑`/`↓` wrap around the matches like the Codex popup. `:accept` replaces the
  token with the selected path followed by a separator space; with nothing
  selected it falls through to a normal submission, which is what Enter means
  everywhere else in the composer.
  """
  @spec handle(atom(), Tackle.CLI.TUI.State.t()) ::
          {:noreply, Tackle.CLI.TUI.State.t()} | {:noreply, Tackle.CLI.TUI.State.t(), keyword()}
  def handle(:previous, state), do: {:noreply, move(state, -1)}
  def handle(:next, state), do: {:noreply, move(state, 1)}

  def handle(:close, %{overlay: {:file_search, popup}} = state) do
    {start, _stop} = popup.range
    dismissed = {start, popup.query}

    {:noreply, %{state | overlay: nil, file_search: %{state.file_search | dismissed: dismissed}}}
  end

  def handle(:accept, %{overlay: {:file_search, popup}} = state) do
    case Enum.at(popup.matches, popup.selected) do
      nil -> Tackle.CLI.TUI.Composer.submit(state)
      path -> insert(state, popup, path)
    end
  end

  def handle(:ignore, state), do: {:noreply, state, render?: false}

  defp move(%{overlay: {:file_search, popup}} = state, delta) do
    count = length(popup.matches)

    selected =
      if count == 0, do: 0, else: Integer.mod(popup.selected + delta, count)

    %{state | overlay: {:file_search, %{popup | selected: selected}}}
  end

  defp insert(state, popup, path) do
    {start, stop} = popup.range
    :ok = Input.replace_range(state.input, start, stop, path <> " ")

    state = %{
      state
      | overlay: nil,
        file_search: %{state.file_search | dismissed: nil},
        history: History.leave_browsing(state.history)
    }

    {:noreply, state |> Viewport.update_draft() |> Viewport.relayout()}
  end

  # -- rendering ------------------------------------------------------------

  @doc """
  Builds the popup anchored directly above the composer's rectangle.

  Returns `{widget, rect}` pairs: the shared chrome (a clear plus the panel
  block) and the list or hint inside it. The popup is skipped when the
  terminal is too short to fit it above the input bar. The chrome is shared
  with the `/` command popup through `Tackle.CLI.TUI.CompletionPopup`, so
  the two completions stay visually identical.
  """
  @spec widgets(Tackle.CLI.TUI.State.t(), Rect.t()) :: [{struct(), Rect.t()}]
  def widgets(%{overlay: {:file_search, popup}}, composer) do
    case CompletionPopup.anchor(title(popup), match_rows(popup) |> max(1), composer) do
      :skip -> []
      {chrome, inner} -> chrome ++ [{content(popup), inner}]
    end
  end

  defp match_rows(popup), do: min(length(popup.matches), @max_matches)

  defp content(%{waiting?: true}) do
    %Paragraph{text: " Searching files…", style: Theme.style(:muted)}
  end

  defp content(%{query: ""}) do
    %Paragraph{text: " Type to search files…", style: Theme.style(:muted)}
  end

  defp content(%{matches: []}) do
    %Paragraph{text: " No files match", style: Theme.style(:muted)}
  end

  defp content(%{matches: matches, selected: selected}) do
    %SelectionList{
      items: matches,
      selected: min(selected, max(length(matches) - 1, 0)),
      highlight_symbol: "› ",
      highlight_style: Theme.merge(Theme.style(:selection_surface), Theme.style(:accent)),
      style: Theme.style(:text),
      scroll_padding: 0
    }
  end

  defp title(popup) do
    count = length(popup.matches)

    filter =
      if popup.query == "", do: "type to filter", else: "“#{Util.truncate(popup.query, 24)}”"

    " Files · #{count} · #{filter} "
  end
end
