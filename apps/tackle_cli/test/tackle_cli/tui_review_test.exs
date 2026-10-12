defmodule Tackle.CLI.TUI.ReviewTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ExRatatui.Command
  alias ExRatatui.Event.Key
  alias Tackle.CLI.{Keybinds, TUI}
  alias Tackle.CLI.TUI.{Review, ReviewProgress, ReviewView, SlashCommands, Viewport}
  alias Tackle.CLI.TUI.State, as: TuiState
  alias Tackle.CLI.Widgets.Input
  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.State, as: LibState
  alias Tackle.Review.{Change, Diff, Finding, History, Result}

  doctest Tackle.CLI.TUI.Review

  @patch """
  diff --git a/lib/a.ex b/lib/a.ex
  --- a/lib/a.ex
  +++ b/lib/a.ex
  @@ -1,3 +1,5 @@
   defmodule A do
  -  def run(x), do: x
  +  def run(x) do
  +    File.read!(x)
  +  end
   end
  diff --git a/lib/b.ex b/lib/b.ex
  --- a/lib/b.ex
  +++ b/lib/b.ex
  @@ -1,2 +1,2 @@
   defmodule B do
  -  def go, do: :ok
  +  def go, do: :error
  """

  setup do
    home = Path.join(System.tmp_dir!(), "tackle-tui-review-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)
    {:ok, history} = History.open("/repo", home: home)
    %{home: home, history: history}
  end

  # -- fixtures ---------------------------------------------------------------

  defp base_state(opts \\ []) do
    input = Input.new()
    :ok = Input.set_value(input, Keyword.get(opts, :draft, ""))

    state = %TuiState{
      input: input,
      size: Keyword.get(opts, :size, {120, 40}),
      conversation: Viewport.new_conversation(120, 40),
      agent_state: LibState.new(),
      agent_ref: :agent_ref,
      scope_ref: :scope_ref,
      session_id: "session-1",
      cwd: "/repo",
      env: %{},
      active_turn: Keyword.get(opts, :active_turn),
      review: Keyword.get(opts, :review),
      overlay: Keyword.get(opts, :overlay),
      usage_timeline_loader: fn _mode, _id -> {:error, :test} end
    }

    Viewport.update_draft(state)
  end

  defp change(patch \\ @patch) do
    {:ok, diff} = Diff.parse(patch)

    %Change{
      cwd: "/repo",
      root: "/repo",
      mode: :branch,
      base_ref: "main",
      base_sha: "abc",
      head_sha: :worktree,
      diff: diff
    }
  end

  defp finding(path, line, opts \\ []) do
    %Finding{
      title: Keyword.get(opts, :title, "Handle the read failure"),
      category: :correctness,
      severity: Keyword.get(opts, :severity, :high),
      blocking: Keyword.get(opts, :blocking, true),
      confidence: 0.8,
      rule_id: Keyword.get(opts, :rule_id, "unhandled-error"),
      location: %{path: path, side: :new, start_line: line, end_line: line},
      trigger: "the file does not exist",
      body: "File.read!/1 raises when the file is missing.",
      suggestion: Keyword.get(opts, :suggestion, "File.read(x)"),
      verdict: :confirmed,
      fingerprint: Keyword.get(opts, :fingerprint, "fp-#{path}-#{line}")
    }
  end

  defp summary(blocking, optional) do
    %{
      profile: :default,
      samples: 1,
      units: 3,
      files: ["lib/a.ex", "lib/b.ex"],
      skipped: [],
      failed_units: [],
      detected: 2,
      candidates: 2,
      confirmed: 2,
      uncertain: 0,
      rejected: 0,
      verification_failures: [],
      scoring_failures: [],
      blocking: length(blocking),
      optional: length(optional),
      verdict: Result.verdict(blocking, optional),
      warnings: []
    }
  end

  defp result(blocking, optional) do
    %Result{blocking: blocking, optional: optional, summary: summary(blocking, optional)}
  end

  defp done_review(history, opts \\ []) do
    blocking = Keyword.get(opts, :blocking, [finding("lib/a.ex", 3)])

    optional =
      Keyword.get(opts, :optional, [
        finding("lib/b.ex", 2,
          blocking: false,
          severity: :low,
          rule_id: nil,
          title: "Name the error"
        )
      ])

    %Review{
      ref: make_ref(),
      status: :done,
      change: change(),
      history: history,
      blocking: blocking,
      optional: optional,
      summary: summary(blocking, optional)
    }
  end

  defp open(review, opts \\ []),
    do: base_state(Keyword.merge([review: review, overlay: {:review, %{}}], opts))

  defp key(code, modifiers \\ []), do: %Key{code: code, modifiers: modifiers}

  defp row_text(row), do: Enum.map_join(row.spans, & &1.content)

  defp overlay_text(state) do
    {width, height} = state.size
    terminal = ExRatatui.init_test_terminal(width, height)
    :ok = ExRatatui.draw(terminal, ReviewView.widgets(state))
    ExRatatui.get_buffer_content(terminal)
  end

  defp events(history) do
    {:ok, events} = History.finding_events(history)
    Enum.map(events, &{&1["event"], &1["fingerprint"]})
  end

  # -- registration -----------------------------------------------------------

  describe "slash commands" do
    test "/review is registered idle-only and /findings is always available" do
      assert %{name: "review", action: :review, idle_only?: true} = SlashCommands.find("review")
      assert %{name: "findings", action: :findings} = SlashCommands.find("findings")

      busy = SlashCommands.commands(base_state(active_turn: %{id: "turn"}))
      names = Enum.map(busy, & &1.name)
      refute "review" in names
      assert "findings" in names
    end

    test "/review starts a background review, opens the overlay, and clears the draft" do
      state = base_state(draft: "/review")

      assert {:noreply, state, opts} = SlashCommands.dispatch(state, "/review")
      assert [%Command{kind: :async}] = opts[:commands]
      assert {:review, _view} = state.overlay

      assert %Review{status: :loading, mode: :full, target: %{range: nil, staged: false}} =
               state.review

      assert is_reference(state.review.ref)
      assert %Cancellation.Signal{} = state.review.signal
      assert Input.get_value(state.input) == ""
    end

    test "/review passes a range or --staged through" do
      {:noreply, state, _opts} = SlashCommands.dispatch(base_state(), "/review main..HEAD")
      assert state.review.target == %{range: "main..HEAD", staged: false}

      {:noreply, state, _opts} = SlashCommands.dispatch(base_state(), "/review --staged")
      assert state.review.target == %{range: nil, staged: true}
    end

    test "/review with invalid arguments keeps the draft and explains the usage" do
      state = base_state(draft: "/review a b")

      assert {:noreply, state} = SlashCommands.dispatch(state, "/review a b")
      assert state.overlay == nil
      assert state.review == nil
      assert state.notice =~ "Usage: /review"
      assert Input.get_value(state.input) == "/review a b"

      assert {:error, _usage} = Review.parse_args("--bogus")
    end

    test "/review refuses during a turn and keeps the draft" do
      state = base_state(draft: "/review", active_turn: %{id: "turn"})

      assert {:noreply, state} = SlashCommands.dispatch(state, "/review")
      assert state.review == nil
      assert state.notice =~ "available when idle"
      assert Input.get_value(state.input) == "/review"
    end

    test "/review while a review runs reopens it instead of starting another" do
      running = %Review{ref: make_ref(), status: :running}
      state = base_state(review: running)

      assert {:noreply, state} = SlashCommands.dispatch(state, "/review")
      assert {:review, _view} = state.overlay
      assert state.review == running
      assert state.notice =~ "already running"
    end

    test "/findings reopens the last review, or says there is none", %{history: history} do
      assert {:noreply, state} =
               SlashCommands.dispatch(base_state(draft: "/findings"), "/findings")

      assert state.overlay == nil
      assert state.notice =~ "No review"
      assert Input.get_value(state.input) == "/findings"

      review = done_review(history)
      state = base_state(draft: "/findings", review: review)
      assert {:noreply, state} = SlashCommands.dispatch(state, "/findings")
      assert {:review, _view} = state.overlay
      assert state.review == review
    end
  end

  # -- background messages ----------------------------------------------------

  describe "background messages" do
    setup do
      {:noreply, state, _opts} = SlashCommands.dispatch(base_state(), "/review")
      %{state: state, ref: state.review.ref}
    end

    test "messages of another review are ignored", %{state: state} do
      assert {:noreply, ^state, render?: false} =
               Review.apply(state, make_ref(), {:event, {:started, %{units: 2}}})
    end

    test "loading, progress, and the result move the review to its findings", %{
      state: state,
      ref: ref,
      history: history
    } do
      {:noreply, state} = Review.apply(state, ref, {:loaded, change(), history, nil, []})
      assert %Review{status: :running, change: %Change{}, history: ^history} = state.review

      {:noreply, state} = Review.apply(state, ref, {:event, {:started, %{units: 2}}})
      {:noreply, state} = Review.apply(state, ref, {:event, {:unit, "lib/a.ex#1", :started}})
      assert ReviewProgress.counts(state.review.progress).running == 1

      # An event the projection ignores does not redraw.
      assert {:noreply, ^state, render?: false} =
               Review.apply(state, ref, {:event, {:done, :ignored}})

      blocking = [finding("lib/a.ex", 3)]

      {:noreply, state} =
        Review.apply(state, ref, {:finished, {:ok, result(blocking, [])}})

      assert %Review{status: :done, blocking: ^blocking, optional: []} = state.review
      assert state.notice == "Review finished: 1 blocking, 0 optional"
    end

    test "a review that finishes behind a closed overlay points at /findings", %{
      state: state,
      ref: ref
    } do
      state = %{state | overlay: nil}
      {:noreply, state} = Review.apply(state, ref, {:finished, {:ok, result([], [])}})
      assert state.notice =~ "/findings opens it"
    end

    test "failures and cancellation end a full review without findings", %{
      state: state,
      ref: ref
    } do
      {:noreply, failed} =
        Review.apply(state, ref, {:finished, {:error, {:change, :no_default_branch}}})

      assert %Review{status: :failed, error: error} = failed.review
      assert error =~ "default branch"

      {:noreply, crashed} =
        Review.apply(state, ref, {:finished, {:error, {:exception, "boom"}}})

      assert crashed.review.error == "boom"

      {:noreply, cancelled} = Review.apply(state, ref, {:finished, {:error, :cancelled}})
      assert cancelled.review.status == :cancelled
    end
  end

  # -- keybinds ---------------------------------------------------------------

  test "review keybinds resolve to intents" do
    assert Keybinds.review(key("esc")) == :close
    assert Keybinds.review(key("up")) == :previous
    assert Keybinds.review(key("k")) == :previous
    assert Keybinds.review(key("down")) == :next
    assert Keybinds.review(key("j")) == :next
    assert Keybinds.review(key("page_up")) == {:scroll, :up}
    assert Keybinds.review(key("page_down")) == {:scroll, :down}
    assert Keybinds.review(key("u")) == {:outcome, :useful}
    assert Keybinds.review(key("n")) == {:outcome, :not_useful}
    assert Keybinds.review(key("d")) == {:outcome, :dismissed}
    assert Keybinds.review(key("f")) == :fix
    assert Keybinds.review(key("F")) == :fix_blocking
    assert Keybinds.review(key("F", ["shift"])) == :fix_blocking
    assert Keybinds.review(key("f", ["shift"])) == :fix_blocking
    assert Keybinds.review(key("r")) == :rereview
    assert Keybinds.review(key("x")) == :cancel
    assert Keybinds.review(key("f", ["ctrl"])) == :ignore
    assert Keybinds.review(key("q")) == :ignore

    assert Keybinds.review_repeatable?(key("down"))
    assert Keybinds.review_repeatable?(key("page_down"))
    refute Keybinds.review_repeatable?(key("f"))
    refute Keybinds.review_repeatable?(key("u"))
  end

  test "the help reference lists /review, /findings, and the overlay keys" do
    state = base_state(overlay: {:help, %{offset: 0}}, size: {120, 200})
    %{content: %{text: text}} = Tackle.CLI.TUI.Help.popup(state)

    for entry <- [
          "/review [range | --staged]",
          "/findings",
          "Review (/review)",
          "u / n         mark useful / not useful",
          "d             dismiss",
          "f / F         ask the agent to fix it / all blocking",
          "r             re-review",
          "Esc           close"
        ] do
      assert text =~ entry
    end
  end

  test "keys reach the overlay through the shell's dispatch", %{history: history} do
    state = open(done_review(history))

    {:noreply, state} = TUI.handle_event(key("j"), state)
    assert state.review.selected == 1

    # A held `u` does not record feedback again.
    {:noreply, state, opts} =
      TUI.handle_event(%Key{code: "u", modifiers: [], kind: "repeat"}, state)

    assert opts[:render?] == false

    assert events(history) == []

    {:noreply, state} = TUI.handle_event(key("esc"), state)
    assert state.overlay == nil
    assert %Review{} = state.review
  end

  # -- overlay intents --------------------------------------------------------

  describe "overlay intents" do
    test "selection wraps and resets the detail scroll", %{history: history} do
      state = open(%{done_review(history) | scroll: 4})

      {:noreply, state} = Review.handle(:previous, state)
      assert state.review.selected == 1
      assert state.review.scroll == 0

      {:noreply, state} = Review.handle(:next, state)
      assert state.review.selected == 0

      {:noreply, state} = Review.handle({:scroll, :down}, state)
      {:noreply, state} = Review.handle({:scroll, :down}, state)
      {:noreply, state} = Review.handle({:scroll, :up}, state)
      assert state.review.scroll == 1
    end

    test "feedback is recorded in the history and shown on the finding", %{history: history} do
      state = open(done_review(history))
      [first, second] = Review.findings(state.review)

      {:noreply, state} = Review.handle({:outcome, :useful}, state)
      assert state.notice == "Marked useful"
      {:noreply, state} = Review.handle(:next, state)
      {:noreply, state} = Review.handle({:outcome, :not_useful}, state)
      {:noreply, state} = Review.handle({:outcome, :dismissed}, state)
      assert state.notice =~ "Dismissed"

      assert events(history) == [
               {"useful", first.fingerprint},
               {"not_useful", second.fingerprint},
               {"dismissed", second.fingerprint}
             ]

      assert state.review.outcomes == %{
               first.fingerprint => :useful,
               second.fingerprint => :dismissed
             }

      assert {:ok, dismissed} = History.fingerprints(history, [:dismissed])
      assert MapSet.to_list(dismissed) == [second.fingerprint]
    end

    test "feedback without history is kept locally and says it was not saved", %{
      history: history
    } do
      state = open(%{done_review(history) | history: nil})

      {:noreply, state} = Review.handle({:outcome, :useful}, state)
      assert state.notice =~ "not saved"
      assert map_size(state.review.outcomes) == 1
    end

    test "a history write failure is reported", %{history: history} do
      # A file where the history directory belongs makes every write fail.
      File.mkdir_p!(Path.dirname(history.dir))
      File.write!(history.dir, "not a directory")
      state = open(done_review(history))

      {:noreply, state} = Review.handle({:outcome, :useful}, state)
      assert state.notice =~ "Marked useful · not saved:"
      assert map_size(state.review.outcomes) == 1
      assert File.regular?(history.dir)
    end

    test "feedback without findings does nothing" do
      state = open(%Review{ref: make_ref(), status: :running})
      {:noreply, state} = Review.handle({:outcome, :useful}, state)
      assert state.notice == "No finding selected"
    end

    test "f sends the selected finding to the agent and records it as fixed", %{
      history: history
    } do
      state = open(done_review(history))
      [first | _rest] = Review.findings(state.review)

      assert {:noreply, state, opts} = Review.handle(:fix, state)
      assert [%Command{kind: :async}] = opts[:commands]
      assert state.overlay == nil
      assert %{kind: :submit, prompt: prompt} = state.pending_operation
      assert prompt =~ "Fix this code review finding"
      assert prompt =~ "lib/a.ex:3"
      assert prompt =~ "Trigger: the file does not exist"
      assert prompt =~ "Suggested fix:\nFile.read(x)"
      assert state.notice =~ "/findings reopens"
      assert state.review.outcomes == %{first.fingerprint => :fixed}
      assert events(history) == [{"fixed", first.fingerprint}]
    end

    test "F sends every blocking finding that was not dismissed", %{history: history} do
      blocking = [
        finding("lib/a.ex", 3),
        finding("lib/a.ex", 4, title: "Close the file"),
        finding("lib/b.ex", 2, title: "Return ok")
      ]

      review = done_review(history, blocking: blocking)
      [_a, dismissed, _b] = blocking
      review = %{review | outcomes: %{dismissed.fingerprint => :dismissed}}

      assert {:noreply, state, _opts} = Review.handle(:fix_blocking, open(review))
      assert state.pending_operation.prompt =~ "Fix these 2 code review findings"
      refute state.pending_operation.prompt =~ "Close the file"
      assert length(events(history)) == 2
    end

    test "F without blocking findings only says so", %{history: history} do
      state = open(done_review(history, blocking: []))
      assert {:noreply, state} = Review.handle(:fix_blocking, state)
      assert state.notice == "No blocking findings to fix"
      assert state.pending_operation == nil
    end

    test "fixes wait for an idle agent and an empty draft", %{history: history} do
      busy = open(done_review(history), active_turn: %{id: "turn"})
      assert {:noreply, busy} = Review.handle(:fix, busy)
      assert busy.notice =~ "idle"
      assert {:review, _view} = busy.overlay

      drafted = open(done_review(history), draft: "keep me")
      assert {:noreply, drafted} = Review.handle(:fix, drafted)
      assert drafted.notice =~ "Clear the draft"
      assert Input.get_value(drafted.input) == "keep me"

      assert events(history) == []
    end

    test "x cancels a running review once", %{history: history} do
      signal = Cancellation.new_signal()
      state = open(%Review{ref: make_ref(), status: :running, signal: signal})

      {:noreply, state} = Review.handle(:cancel, state)
      assert state.review.status == :cancelling
      assert Cancellation.cancelled?(signal)

      assert {:noreply, _state, render?: false} = Review.handle(:cancel, state)

      assert {:noreply, _state, render?: false} =
               Review.handle(:cancel, open(done_review(history)))
    end

    test "Esc closes; a running review keeps going in the background" do
      state = open(%Review{ref: make_ref(), status: :running})
      {:noreply, state} = Review.handle(:close, state)
      assert state.overlay == nil
      assert state.review.status == :running
      assert state.notice =~ "/findings reopens it"
    end

    test "discarding a running review cancels it" do
      signal = Cancellation.new_signal()
      assert Review.discard(%Review{status: :running, signal: signal}) == nil
      assert Cancellation.cancelled?(signal)
      assert Review.discard(nil) == nil
    end
  end

  # -- re-review --------------------------------------------------------------

  describe "re-review" do
    test "r is refused while running, while the agent works, or before a change" do
      running = open(%Review{ref: make_ref(), status: :running})
      assert {:noreply, state} = Review.handle(:rereview, running)
      assert state.notice =~ "still running"

      busy =
        open(%Review{ref: make_ref(), status: :done, change: change()}, active_turn: %{id: "t"})

      assert {:noreply, state} = Review.handle(:rereview, busy)
      assert state.notice =~ "idle"

      failed = open(%Review{ref: make_ref(), status: :failed})
      assert {:noreply, state} = Review.handle(:rereview, failed)
      assert state.notice =~ "/review starts a new one"

      nothing = open(%Review{ref: make_ref(), status: :done})
      assert {:noreply, state} = Review.handle(:rereview, nothing)
      assert state.notice =~ "Nothing to re-review"
    end

    test "r does not re-review a change whose review was cancelled or failed", %{
      history: history
    } do
      {:noreply, started, _opts} = SlashCommands.dispatch(base_state(), "/review")
      ref = started.review.ref
      {:noreply, loaded} = Review.apply(started, ref, {:loaded, change(), history, nil, []})
      assert %Review{status: :running, change: %Change{}} = loaded.review

      # Cancelled with x, then the background run reports the cancellation.
      {:noreply, cancelling} = Review.handle(:cancel, loaded)
      {:noreply, cancelled} = Review.apply(cancelling, ref, {:finished, {:error, :cancelled}})
      assert cancelled.review.status == :cancelled
      refute Review.rereviewable?(cancelled.review)

      assert {:noreply, after_cancel} = Review.handle(:rereview, cancelled)
      assert after_cancel.notice =~ "did not finish"
      assert after_cancel.review == cancelled.review

      # A full review that failed is not re-reviewable either.
      {:noreply, failed} =
        Review.apply(loaded, ref, {:finished, {:error, {:detection_failed, []}}})

      assert failed.review.status == :failed
      refute Review.rereviewable?(failed.review)

      assert {:noreply, after_failure} = Review.handle(:rereview, failed)
      assert after_failure.notice =~ "did not finish"
      assert after_failure.review == failed.review

      # Neither overlay offers r; a finished review does.
      for state <- [cancelled, failed] do
        refute overlay_text(%{state | notice: nil}) =~ "r re-review"
      end

      {:noreply, finished} = Review.apply(loaded, ref, {:finished, {:ok, result([], [])}})
      assert Review.rereviewable?(finished.review)
      assert overlay_text(%{finished | notice: nil}) =~ "r re-review"
    end

    test "r re-reviews touched files and merges their findings", %{history: history} do
      kept = finding("lib/b.ex", 2, title: "Untouched file finding")
      replaced = finding("lib/a.ex", 3, title: "Old finding")

      review = done_review(history, blocking: [replaced, kept], optional: [])
      review = %{review | outcomes: %{kept.fingerprint => :useful}, selected: 1}

      assert {:noreply, state, opts} = Review.handle(:rereview, open(review))
      assert [%Command{kind: :async}] = opts[:commands]
      assert %Review{status: :loading, mode: :rereview} = state.review
      ref = state.review.ref
      refute ref == review.ref

      # lib/a.ex changed again; lib/b.ex is identical.
      next =
        change(String.replace(@patch, "File.read!(x)", "File.read(x)"))

      assert Review.touched_paths(review.change, next) == ["lib/a.ex"]

      {:noreply, state} = Review.apply(state, ref, {:loaded, next, history, ["lib/a.ex"], []})
      assert state.review.status == :running
      # The previous findings stay visible while the re-review runs.
      assert state.review.change == review.change

      fresh = finding("lib/a.ex", 4, title: "New finding", fingerprint: "fresh")
      {:noreply, state} = Review.apply(state, ref, {:finished, {:ok, result([fresh], [])}})

      assert %Review{status: :done, change: ^next} = state.review

      assert Enum.map(state.review.blocking, & &1.title) == [
               "Untouched file finding",
               "New finding"
             ]

      assert state.review.outcomes == %{kept.fingerprint => :useful}
      assert state.notice == "Re-reviewed 1 changed file: 2 blocking, 0 optional"
    end

    test "findings of files that left the change are dropped", %{history: history} do
      review = done_review(history)

      only_a =
        @patch
        |> String.split("diff --git a/lib/b.ex")
        |> hd()
        |> String.replace("File.read!(x)", "File.read(x)")

      {:noreply, state, _opts} = Review.handle(:rereview, open(review))
      ref = state.review.ref

      {:noreply, state} =
        Review.apply(state, ref, {:loaded, change(only_a), history, ["lib/a.ex"], []})

      {:noreply, state} = Review.apply(state, ref, {:finished, {:ok, result([], [])}})

      assert Review.findings(state.review) == []
      assert state.review.status == :done
      assert state.notice == "Re-reviewed 1 changed file: 0 blocking, 0 optional"
    end

    test "an unchanged re-review keeps the findings", %{history: history} do
      review = done_review(history)

      {:noreply, state, _opts} = Review.handle(:rereview, open(review))
      ref = state.review.ref
      {:noreply, state} = Review.apply(state, ref, {:loaded, change(), history, [], []})
      {:noreply, state} = Review.apply(state, ref, {:finished, {:ok, :unchanged}})

      assert state.notice == "Nothing changed since the review"
      assert Review.findings(state.review) == Review.findings(review)
      assert state.review.change == review.change
      assert state.review.status == :done
    end

    test "a failed re-review keeps the previous findings", %{history: history} do
      review = done_review(history)
      {:noreply, state, _opts} = Review.handle(:rereview, open(review))

      {:noreply, state} =
        Review.apply(state, state.review.ref, {:finished, {:error, {:detection_failed, []}}})

      assert state.review.status == :done
      assert state.review.blocking == review.blocking
      assert state.notice =~ "Re-review failed"
    end

    test "touched_paths lists changed and new files, not removed ones" do
      before = change()
      only_a = @patch |> String.split("diff --git a/lib/b.ex") |> hd()

      assert Review.touched_paths(before, before) == []
      assert Review.touched_paths(before, change(only_a)) == []
      assert Review.touched_paths(change(only_a), before) == ["lib/b.ex"]
    end
  end

  # -- background command -----------------------------------------------------

  describe "execute/2" do
    test "reports an unloadable change without notifying", %{home: home} do
      cwd = Path.join(home, "not-a-repo")
      File.mkdir_p!(cwd)
      parent = self()

      assert {:error, {:change, {:not_a_git_repository, _path}}} =
               Review.execute(request(cwd, home), &send(parent, &1))

      refute_received {:loaded, _change, _history, _paths, _notes}
    end

    test "does not look for the repository above the session's workspace", %{home: home} do
      repo = git_repo(home)
      workspace = Path.join(repo, "nested")
      File.mkdir_p!(workspace)
      parent = self()
      request = %{request(workspace, home) | workspace: workspace}

      # As for `git` in a jail that mounts only the workspace.
      assert {:error, {:change, {:not_a_git_repository, ^workspace}}} =
               Review.execute(request, &send(parent, &1))

      refute_received {:loaded, _change, _history, _paths, _notes}
    end

    test "a re-review of an unchanged change reports it loaded and skips the review", %{
      home: home
    } do
      repo = git_repo(home)
      {:ok, previous} = Change.load(cwd: repo)
      parent = self()

      assert {:ok, :unchanged} =
               Review.execute(%{request(repo, home) | previous: previous}, &send(parent, &1))

      assert_received {:loaded, %Change{root: root}, %History{} = history, [], []}
      assert root == Path.expand(repo)
      assert String.starts_with?(history.dir, Path.join(home, "tackle-home"))
    end

    defp request(cwd, home) do
      %{
        cwd: cwd,
        workspace: nil,
        env: %{"TACKLE_HOME" => Path.join(home, "tackle-home")},
        range: nil,
        staged: false,
        requester: :unused,
        scope_ref: :unused,
        signal: Cancellation.new_signal(),
        previous: nil
      }
    end

    defp git_repo(home) do
      repo = Path.join(home, "repo")
      File.mkdir_p!(repo)
      git(repo, ["init", "--quiet", "--initial-branch=main"])
      File.write!(Path.join(repo, "a.ex"), "defmodule A do\nend\n")
      git(repo, ["add", "a.ex"])
      git(repo, ["commit", "--quiet", "-m", "init"])
      git(repo, ["checkout", "--quiet", "-b", "feature"])
      File.write!(Path.join(repo, "a.ex"), "defmodule A do\n  def a, do: 1\nend\n")
      repo
    end

    defp git(repo, args) do
      env = [
        {"GIT_AUTHOR_NAME", "t"},
        {"GIT_AUTHOR_EMAIL", "t@example.com"},
        {"GIT_COMMITTER_NAME", "t"},
        {"GIT_COMMITTER_EMAIL", "t@example.com"},
        {"GIT_CONFIG_GLOBAL", "/dev/null"},
        {"GIT_CONFIG_NOSYSTEM", "1"}
      ]

      {_output, 0} = System.cmd("git", args, cd: repo, env: env, stderr_to_stdout: true)
    end
  end

  # -- rendering --------------------------------------------------------------

  describe "rendering" do
    test "the list groups findings with severity, location, title, rule, and feedback", %{
      history: history
    } do
      review = done_review(history)
      [first | _rest] = Review.findings(review)
      review = %{review | outcomes: %{first.fingerprint => :useful}}

      rows = review |> ReviewView.list_rows(80, 10) |> Enum.map(&row_text/1)

      assert [
               "Blocking (1)",
               "› HIGH   lib/a.ex:3  Handle the read failure  unhandled-error  ✓ useful" <> _pad,
               "Optional (1)",
               "  LOW    lib/b.ex:2  Name the error"
             ] = rows
    end

    test "the list scrolls to keep the selection visible", %{history: history} do
      optional = for line <- 1..6, do: finding("lib/a.ex", line, blocking: false)
      review = %{done_review(history, optional: optional) | selected: 6}

      rows = review |> ReviewView.list_rows(80, 3) |> Enum.map(&row_text/1)
      assert length(rows) == 3
      assert List.last(rows) =~ "› "
    end

    test "the detail pane shows the explanation, trigger, suggestion, and code", %{
      history: history
    } do
      text =
        history
        |> done_review()
        |> ReviewView.detail_rows(100, 60)
        |> Enum.map_join("\n", &row_text/1)

      assert text =~ "Handle the read failure"
      assert text =~ "high · correctness · rule unhandled-error · blocking · confirmed"
      assert text =~ "File.read!/1 raises"
      assert text =~ "Trigger\nthe file does not exist"
      assert text =~ "Suggestion\nFile.read(x)"
      assert text =~ "Code\n"
      assert text =~ "▌3 +     File.read!(x)"
      assert text =~ " 2 +   def run(x) do"
    end

    test "excerpt cuts the lines around the location, both sides kept" do
      finding = finding("lib/a.ex", 3)

      excerpt = ReviewView.excerpt(change(), finding.location)
      assert Enum.map(excerpt, & &1.kind) == [:context, :remove, :add, :add, :add, :context]

      missing = %{finding.location | path: "nope.ex"}
      assert ReviewView.excerpt(change(), missing) == []
    end

    test "progress shows units and candidates with their verdicts" do
      progress =
        [
          {:started, %{units: 3}},
          {:unit, "change", :started},
          {:unit, "lib/a.ex#1", :started},
          {:unit, "change", :done},
          {:unit, "lib/a.ex#1", {:failed, :timeout}},
          {:unit, "lib/b.ex#1", :started},
          {:candidate, finding("lib/a.ex", 3)},
          {:verdict, "fp-lib/a.ex-3", :rejected}
        ]
        |> Enum.reduce(ReviewProgress.new(), &ReviewProgress.apply(&2, &1))

      review = %Review{status: :running, progress: progress}
      text = review |> ReviewView.progress_rows(100, 20) |> Enum.map_join("\n", &row_text/1)

      assert text =~ "● Detecting  2/3 units · 1 failed"
      assert text =~ "✓ the change overview"
      assert text =~ "✗ lib/a.ex#1  failed:"
      assert text =~ "● lib/b.ex#1"
      assert text =~ "✓ Verifying  1/1 candidate · 1 rejected"
      assert text =~ "✗ lib/a.ex:3  Handle the read failure  rejected"

      loading = %Review{status: :loading} |> ReviewView.progress_rows(80, 5)
      assert Enum.map(loading, &row_text/1) == ["● Loading the change from Git…"]
    end

    test "every state draws without errors, wide and narrow", %{history: history} do
      reviews = [
        nil,
        %Review{status: :loading},
        %Review{
          status: :running,
          progress: ReviewProgress.apply(ReviewProgress.new(), {:started, %{units: 2}})
        },
        %Review{status: :failed, error: "boom", notes: ["a note"]},
        %Review{status: :done, summary: summary([], [])},
        %{done_review(history) | status: :running, mode: :rereview, touched: ["lib/a.ex"]},
        done_review(history)
      ]

      for review <- reviews, {width, height} <- [{140, 40}, {60, 16}, {12, 5}] do
        state = open(review, size: {width, height})
        widgets = ReviewView.widgets(state)
        terminal = ExRatatui.init_test_terminal(width, height)
        assert :ok = ExRatatui.draw(terminal, widgets)
      end
    end

    test "the scene paints the overlay through the shell's view", %{history: history} do
      state = open(done_review(history))
      frame = %ExRatatui.Frame{width: 120, height: 40}
      widgets = TUI.scene(state, frame)

      assert Enum.any?(widgets, fn {widget, _rect} ->
               match?(%ExRatatui.Widgets.Clear{}, widget)
             end)
    end
  end

  # -- progress projection ----------------------------------------------------

  describe "ReviewProgress" do
    test "folds events into counts and phases" do
      model = ReviewProgress.new()
      assert ReviewProgress.phase(model) == :starting

      model = ReviewProgress.apply(model, {:started, %{units: 2}})
      model = ReviewProgress.apply(model, {:unit, "a#1", :started})
      assert ReviewProgress.phase(model) == :detecting

      model = ReviewProgress.apply(model, {:unit, "a#1", :done})
      model = ReviewProgress.apply(model, {:unit, "b#1", {:failed, :boom}})
      model = ReviewProgress.apply(model, {:candidate, finding("a", 1)})
      assert ReviewProgress.phase(model) == :verifying

      model = ReviewProgress.apply(model, {:verdict, "fp-a-1", :confirmed})
      assert ReviewProgress.phase(model) == :ranking

      assert %{done: 1, failed: 1, running: 0, candidates: 1, confirmed: 1, verifying: 0} =
               ReviewProgress.counts(model)
    end

    test "records verdicts of unseen candidates and ignores other events" do
      model = ReviewProgress.apply(ReviewProgress.new(), {:verdict, "unknown", :uncertain})
      assert [%{fingerprint: "unknown", finding: nil, verdict: :uncertain}] = model.candidates

      assert ReviewProgress.apply(model, {:done, :result}) === model
      assert ReviewProgress.apply(model, {:error, :boom}) === model
    end
  end
end
