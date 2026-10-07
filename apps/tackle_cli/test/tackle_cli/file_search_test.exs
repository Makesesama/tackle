defmodule Tackle.CLI.FileSearchTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ExRatatui.Event.Key
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Block, List}
  alias Tackle.CLI.{Keybinds, TUI}
  alias Tackle.CLI.TUI.{FileSearch, Viewport}
  alias Tackle.CLI.TUI.State, as: TuiState
  alias Tackle.CLI.Widgets.Input
  alias Tackle.Lib.State, as: LibState

  defp entries(paths), do: Enum.map(paths, &{String.downcase(&1), &1})

  defp index do
    entries([
      "lib/tackle_cli.ex",
      "lib/tackle_cli/tui.ex",
      "test/tackle_cli/tui_test.exs",
      "README.md"
    ])
  end

  defp base_state(opts) do
    input = Input.new()
    :ok = Input.set_value(input, Keyword.get(opts, :draft, ""))

    state = %TuiState{
      input: input,
      size: {80, 24},
      conversation: Viewport.new_conversation(80, 24),
      agent_state: LibState.new(),
      agent_ref: :agent_ref,
      session_id: "session-1",
      file_search: %FileSearch{index: Keyword.get(opts, :index, index())}
    }

    Viewport.update_draft(state)
  end

  defp synced(opts) do
    {state, []} = opts |> base_state() |> FileSearch.sync()
    state
  end

  # -- token detection ------------------------------------------------------

  test "token/2 extracts the @token under the caret" do
    assert FileSearch.token("look at @lib", 12) == {8, 12, "lib"}
    assert FileSearch.token("@", 1) == {0, 1, ""}
    assert FileSearch.token("@abcd", 3) == {0, 5, "abcd"}
    assert FileSearch.token("@ab", 0) == {0, 3, "ab"}
    assert FileSearch.token("one @a two @b", 13) == {11, 13, "b"}
    assert FileSearch.token("one\ntwo @x", 10) == {8, 10, "x"}
    assert FileSearch.token("a\t@b", 4) == {2, 4, "b"}
  end

  test "token/2 ignores runs that do not start a token with @" do
    assert FileSearch.token("email a@b.com", 14) == nil
    assert FileSearch.token("hello", 5) == nil
    assert FileSearch.token("no token here", 14) == nil
    assert FileSearch.token("", 0) == nil
  end

  # -- filtering -----------------------------------------------------------

  test "filter/2 ranks substrings above subsequences" do
    index = entries(["xfoo.ex", "fxo.ex", "lib/bar.ex"])

    assert FileSearch.filter(index, "") == []
    assert FileSearch.filter(index, "fo") == ["xfoo.ex", "fxo.ex"]
    assert FileSearch.filter(index, "lfx") == []

    codex_like = entries(["lib/foo.ex"])
    assert FileSearch.filter(codex_like, "lfx") == ["lib/foo.ex"]

    # A subsequence may begin at the very first byte.
    assert FileSearch.filter(entries(["abc.ex"]), "ac") == ["abc.ex"]
  end

  test "filter/2 orders substring matches by position and caps the rows" do
    index = entries(["lib/foo.ex", "src/lib.ex", "test/lib_test.exs", "README.md"])

    assert FileSearch.filter(index, "lib") == [
             "lib/foo.ex",
             "src/lib.ex",
             "test/lib_test.exs"
           ]

    wide = entries(Enum.map(1..20, &"dir/file-#{&1}.ex"))
    assert length(FileSearch.filter(wide, "file")) == 8
  end

  # -- workspace index -----------------------------------------------------

  test "index/1 walks the workspace and skips hidden, build, and symlinked paths" do
    suffix = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
    root = Path.join(System.tmp_dir!(), "tackle-file-search-#{suffix}")
    outside = Path.join(System.tmp_dir!(), "tackle-outside-#{suffix}.txt")
    on_exit(fn -> File.rm_rf!(root) && File.rm(outside) end)

    File.mkdir_p!(Path.join(root, "lib/tackle_cli"))
    File.write!(Path.join(root, "lib/tackle_cli/tui.ex"), "defmodule do\n")
    File.write!(Path.join(root, "lib/notes.txt"), "notes\n")

    File.mkdir_p!(Path.join(root, ".git"))
    File.write!(Path.join(root, ".git/config"), "[core]\n")

    File.mkdir_p!(Path.join(root, "node_modules/pkg"))
    File.write!(Path.join(root, "node_modules/pkg/index.js"), "module.exports\n")

    File.mkdir_p!(Path.join(root, "deps/other"))
    File.write!(Path.join(root, "deps/other/mix.exs"), "dep\n")

    File.write!(outside, "host\n")
    File.ln_s!(outside, Path.join(root, "link.txt"))

    paths = root |> FileSearch.index() |> Enum.map(&elem(&1, 1))

    assert "lib/tackle_cli/tui.ex" in paths
    assert "lib/notes.txt" in paths
    assert ["lib/notes.txt", "lib/tackle_cli/tui.ex"] = paths
  end

  test "index/1 visits directories alphabetically so no subtree crowds out another" do
    suffix = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
    root = Path.join(System.tmp_dir!(), "tackle-file-search-order-#{suffix}")
    on_exit(fn -> File.rm_rf!(root) end)

    # "z" is created first; a reversed walk would index it before "a" and,
    # against the file cap, could exhaust the budget before "a" at all.
    File.mkdir_p!(Path.join(root, "z"))
    File.write!(Path.join(root, "z/last.txt"), "")
    File.mkdir_p!(Path.join(root, "a/nested"))
    File.write!(Path.join(root, "a/first.txt"), "")
    File.write!(Path.join(root, "a/nested/inner.txt"), "")

    paths = root |> FileSearch.index() |> Enum.map(&elem(&1, 1))

    assert paths == ["a/first.txt", "a/nested/inner.txt", "z/last.txt"]
  end

  # -- popup synchronization ------------------------------------------------

  test "sync opens the popup for an @token and closes it when the token ends" do
    state = synced(draft: "see @lib")
    {:file_search, popup} = state.overlay

    assert popup.query == "lib"
    assert popup.range == {4, 8}
    assert popup.matches == ["lib/tackle_cli.ex", "lib/tackle_cli/tui.ex"]
    refute popup.waiting?

    :ok = Input.insert_str(state.input, " there")
    {state, commands} = FileSearch.sync(state)

    assert commands == []
    assert state.overlay == nil
  end

  test "sync builds the workspace index once, asynchronously" do
    state = base_state(draft: "@", index: nil)
    {state, commands} = FileSearch.sync(state)

    assert [%ExRatatui.Command{kind: :async}] = commands
    {:file_search, popup} = state.overlay
    assert popup.waiting?
    assert popup.matches == []
    assert is_reference(state.file_search.index_ref)

    # While the walk is in flight no second one is started.
    {_state, commands} = FileSearch.sync(state)
    assert commands == []
  end

  test "apply_index installs the latest result and refreshes the open popup" do
    state = base_state(draft: "@lib", index: nil)
    {state, _commands} = FileSearch.sync(state)
    ref = state.file_search.index_ref

    {:noreply, state, commands: []} = FileSearch.apply_index(state, ref, index())
    {:file_search, popup} = state.overlay

    refute popup.waiting?
    assert popup.matches == ["lib/tackle_cli.ex", "lib/tackle_cli/tui.ex"]

    # A stale result from a superseded walk changes nothing.
    {:noreply, state, render?: false} = FileSearch.apply_index(state, make_ref(), [])
    assert state.file_search.index == index()
  end

  test "sync leaves other overlays alone and closes the popup when focus leaves" do
    picker = {:picker, %{kind: :model}}
    state = %{base_state(draft: "@lib") | overlay: picker}
    {state, commands} = FileSearch.sync(state)

    assert commands == []
    assert state.overlay == picker

    state = synced(draft: "@lib")
    {state, commands} = FileSearch.sync(%{state | focus: :transcript})

    assert commands == []
    assert state.overlay == nil
  end

  # -- popup keys -----------------------------------------------------------

  test "Esc dismisses the popup for the current token until it is edited" do
    state = synced(draft: "@lib")

    {:noreply, state} = FileSearch.handle(:close, state)
    assert state.overlay == nil
    assert state.file_search.dismissed == {0, "lib"}

    {state, commands} = FileSearch.sync(state)
    assert commands == []
    assert state.overlay == nil

    :ok = Input.insert_str(state.input, "x")
    {state, commands} = FileSearch.sync(state)

    assert commands == []
    assert {:file_search, %{query: "libx"}} = state.overlay
  end

  test "arrows wrap the selection and accept inserts the full path" do
    state = synced(draft: "see @lib")

    {:noreply, state} = FileSearch.handle(:previous, state)
    {:file_search, %{selected: 1}} = state.overlay

    {:noreply, state} = FileSearch.handle(:next, state)
    {:file_search, %{selected: 0}} = state.overlay

    {:noreply, state} = FileSearch.handle(:accept, state)

    assert Input.get_value(state.input) == "see lib/tackle_cli.ex "
    assert state.overlay == nil
    assert state.file_search.dismissed == nil
  end

  test "accept with nothing selected submits the draft like a plain Enter" do
    state = synced(draft: "@zzz")
    {:file_search, popup} = state.overlay
    assert popup.matches == []

    {:noreply, state, commands: [%ExRatatui.Command{}]} = FileSearch.handle(:accept, state)

    assert Input.get_value(state.input) == ""
    assert state.pending_operation.kind == :submit
  end

  test "file_search keybinds navigate, accept, dismiss, and fall through to typing" do
    assert Keybinds.file_search(%Key{code: "up", modifiers: []}) == :previous
    assert Keybinds.file_search(%Key{code: "down", modifiers: []}) == :next
    assert Keybinds.file_search(%Key{code: "p", modifiers: ["ctrl"]}) == :previous
    assert Keybinds.file_search(%Key{code: "n", modifiers: ["ctrl"]}) == :next
    assert Keybinds.file_search(%Key{code: "esc", modifiers: []}) == :close
    assert Keybinds.file_search(%Key{code: "tab", modifiers: []}) == :accept
    assert Keybinds.file_search(%Key{code: "enter", modifiers: []}) == :accept
    assert Keybinds.file_search(%Key{code: "l", modifiers: []}) == :composer
    assert Keybinds.file_search(%Key{code: "f1", modifiers: []}) == :composer

    refute Keybinds.repeatable?(%Key{code: "tab", modifiers: []})
  end

  # -- rendering ------------------------------------------------------------

  test "widgets anchors the popup above the composer" do
    state = synced(draft: "@lib")
    composer = %Rect{x: 2, y: 20, width: 76, height: 3}

    [{%Block{} = block, rect}, {%List{} = list, inner}] = FileSearch.widgets(state, composer)

    assert rect.x == 2
    assert rect.y + rect.height == composer.y
    assert rect.width == composer.width
    assert block.title =~ "Files"
    assert list.items == ["lib/tackle_cli.ex", "lib/tackle_cli/tui.ex"]
    assert inner.x == rect.x + 1
    assert inner.width == rect.width - 2

    # A terminal too short for the popup skips it rather than clipping.
    assert FileSearch.widgets(state, %Rect{x: 0, y: 2, width: 80, height: 3}) == []
  end

  test "widgets shows hints while searching, on an empty query, and without matches" do
    composer = %Rect{x: 0, y: 20, width: 80, height: 3}

    state = base_state(draft: "@", index: nil)
    {state, _commands} = FileSearch.sync(state)

    assert [{%ExRatatui.Widgets.Paragraph{text: " Searching files…"}, %Rect{}}] =
             tl(FileSearch.widgets(state, composer))

    state = synced(draft: "@")

    assert [{%ExRatatui.Widgets.Paragraph{text: " Type to search files…"}, %Rect{}}] =
             tl(FileSearch.widgets(state, composer))

    state = synced(draft: "@zzz")

    assert [{%ExRatatui.Widgets.Paragraph{text: " No files match"}, %Rect{}}] =
             tl(FileSearch.widgets(state, composer))
  end

  # -- end-to-end key wiring -------------------------------------------------

  test "typing @ opens the popup, arrows select, and Enter inserts the path" do
    state = base_state(draft: "") |> Viewport.refresh()

    {:noreply, state} = TUI.handle_event(%Key{code: "@", modifiers: []}, state)
    assert {:file_search, %{query: "", waiting?: false}} = state.overlay

    {:noreply, state} = TUI.handle_event(%Key{code: "l", modifiers: []}, state)
    assert {:file_search, %{query: "l"}} = state.overlay

    # While the popup is open the arrows move its selection, not history.
    {:noreply, state} = TUI.handle_event(%Key{code: "down", modifiers: []}, state)
    assert {:file_search, %{selected: 1}} = state.overlay

    {:noreply, state} = TUI.handle_event(%Key{code: "enter", modifiers: []}, state)
    assert Input.get_value(state.input) == "lib/tackle_cli/tui.ex "
    assert state.overlay == nil
  end

  test "Esc dismisses the popup through the key path without clearing the draft" do
    state = base_state(draft: "@lib") |> Viewport.refresh()
    {state, _commands} = FileSearch.sync(state)

    {:noreply, state} = TUI.handle_event(%Key{code: "esc", modifiers: []}, state)

    assert state.overlay == nil
    assert Input.get_value(state.input) == "@lib"
  end
end
