defmodule Tackle.Session.TitleTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Lib.LLM
  alias Tackle.Session.Reader
  alias Tackle.Session.Title

  @title_instructions "Generate a concise, single-line task title"

  setup do
    {:ok, home: tmp_home()}
  end

  describe "prompt/1" do
    test "trims the user message and appends it to the instructions" do
      prompt = Title.prompt("  Fix the login form  \n")

      assert prompt =~ @title_instructions
      assert prompt =~ "\n\nUser prompt:\nFix the login form"
    end

    test "bounds the entire prompt without splitting a Unicode character" do
      user_message = String.duplicate("🚀", 2_000)
      prompt = Title.prompt(user_message)

      assert byte_size(prompt) <= 960
      assert String.valid?(prompt)
      assert String.ends_with?(prompt, "🚀")
    end
  end

  describe "normalize/1" do
    test "collapses whitespace and strips wrapping quotes and trailing punctuation" do
      assert {:ok, "Fix the login form"} =
               Title.normalize("  \"  Fix\tthe\nlogin form. \"  ")
    end

    test "truncates to thirty-six codepoints without splitting one" do
      assert {:ok, title} = Title.normalize(String.duplicate("é", 100))
      assert String.length(title) == 36
      assert String.valid?(title)
    end

    test "rejects titles that normalize away entirely" do
      assert {:error, :invalid_title} = Title.normalize("   ")
      assert {:error, :invalid_title} = Title.normalize("\"\"")
      assert {:error, :invalid_title} = Title.normalize(nil)
    end
  end

  describe "generate/3" do
    test "returns the normalized content of a tool-free response" do
      {:ok, selection} = LLM.select([Tackle.Test.Adapter], "test/echo")

      assert {:ok, "Fix the login form"} =
               Title.generate(selection, "Fix the login form",
                 test_pid: self(),
                 content: "  Fix the login form.  "
               )
    end

    test "rejects a response that still contains tool calls" do
      {:ok, selection} = LLM.select([Tackle.Test.Adapter], "test/echo")

      assert {:error, :title_tool_calls} =
               Title.generate(selection, "prompt",
                 test_pid: self(),
                 mode: :tool_then_answer,
                 tool_call: %{id: "1", name: "tool", arguments: %{}}
               )
    end
  end

  describe "automatic generation" do
    test "titles an untitled durable session after its first user message", ctx do
      scope = start_durable_scope(home: ctx.home, root: root_opts())
      {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
      {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "Fix the login form")
      assert_receive {:tackle_turn_finished, _sid, ^turn_id, {:ok, _state}}, 5_000

      session_id = snapshot.session_id

      assert_receive {:tackle_session_title_changed, ^session_id, "Fix the login form"}, 5_000

      {:ok, projection} = Reader.projection(session_id, home: ctx.home)
      assert projection.title == "Fix the login form"

      assert {:ok, summary} = Tackle.session_summary(session_id, home: ctx.home)
      assert summary.title == "Fix the login form"
    end

    test "uses the configured title model for the generation call", ctx do
      scope =
        start_durable_scope(
          home: ctx.home,
          root: root_opts(session_titles: [model: "test/child"])
        )

      {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
      session_id = snapshot.session_id
      {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "Fix the login form")
      assert_receive {:tackle_turn_finished, _sid, ^turn_id, {:ok, _state}}, 5_000

      assert_receive {:adapter_called, _pid, "child", opts}, 5_000
      assert [%{role: :user, content: prompt}] = Keyword.get(opts, :messages)
      assert prompt =~ @title_instructions
      assert prompt =~ "Fix the login form"
      assert opts[:tools] == []

      assert_receive {:tackle_session_title_changed, ^session_id, "Fix the login form"}, 5_000
    end

    test "commits the title while the turn is still running", ctx do
      scope = start_durable_scope(home: ctx.home, root: root_opts(llm_opts: [mode: :manual]))
      {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
      session_id = snapshot.session_id
      {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "Fix the login form")

      # Both the turn and the title generation block inside the adapter, so
      # both supervised tasks are alive at the same time.
      calls =
        Enum.map(1..2, fn _ ->
          assert_receive {:adapter_called, pid, _model, opts}, 5_000
          {pid, opts}
        end)

      [{title_pid, _title_opts}, {turn_pid, _turn_opts}] =
        Enum.sort_by(calls, fn {_pid, opts} -> if title_call?(opts), do: 0, else: 1 end)

      send(title_pid, {:respond, "Fix the login form"})

      # The title commits while the turn task is still blocked in its call.
      assert_receive {:tackle_session_title_changed, ^session_id, "Fix the login form"}, 5_000

      send(turn_pid, {:respond, "answer"})
      assert_receive {:tackle_turn_finished, _sid, ^turn_id, {:ok, _state}}, 5_000
    end

    test "an explicit session title suppresses generation", ctx do
      scope =
        start_durable_scope(
          home: ctx.home,
          session: [title: "Custom title"],
          root: root_opts()
        )

      {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
      {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "Fix the login form")
      assert_receive {:tackle_turn_finished, _sid, ^turn_id, {:ok, _state}}, 5_000

      refute_receive {:tackle_session_title_changed, _sid, _title}, 300

      {:ok, projection} = Reader.projection(snapshot.session_id, home: ctx.home)
      assert projection.title == "Custom title"
    end

    test "generation is disabled without explicit session-titles configuration", ctx do
      scope =
        start_durable_scope(home: ctx.home, root: Keyword.delete(root_opts(), :session_titles))

      {:ok, _snapshot} = Tackle.subscribe(scope.root_agent_ref)
      {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "Fix the login form")
      assert_receive {:tackle_turn_finished, _sid, ^turn_id, {:ok, _state}}, 5_000

      refute_receive {:tackle_session_title_changed, _sid, _title}, 300
    end

    test "a failed generation leaves the session healthy and untitled", ctx do
      # The quoted-empty answer normalizes away, so the title call fails while
      # the turn itself still completes.
      scope =
        start_durable_scope(home: ctx.home, root: root_opts(content: "\"\""))

      {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
      {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "Fix the login form")
      assert_receive {:tackle_turn_finished, _sid, ^turn_id, {:ok, _state}}, 5_000

      refute_receive {:tackle_session_title_changed, _sid, _title}, 300

      {:ok, projection} = Reader.projection(snapshot.session_id, home: ctx.home)
      assert projection.title == nil

      # The session keeps accepting work after the failed title call.
      {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "Another prompt")
      assert_receive {:tackle_turn_finished, _sid, ^turn_id, {:ok, _state}}, 5_000
    end

    test "a resumed session does not regenerate its committed title", ctx do
      scope = start_durable_scope(home: ctx.home, root: root_opts())
      {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
      {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "Fix the login form")
      assert_receive {:tackle_turn_finished, _sid, ^turn_id, {:ok, _state}}, 5_000

      session_id = snapshot.session_id

      assert_receive {:tackle_session_title_changed, ^session_id, "Fix the login form"}, 5_000

      stop_scope(scope.scope_ref)

      resumed =
        start_durable_scope(home: ctx.home, session: [session_id: session_id], root: root_opts())

      {:ok, snapshot} = Tackle.subscribe(resumed.root_agent_ref)
      assert snapshot.session_title == "Fix the login form"

      {:ok, turn_id} = Tackle.submit(resumed.root_agent_ref, "Follow-up prompt")
      assert_receive {:tackle_turn_finished, _sid, ^turn_id, {:ok, _state}}, 5_000

      refute_receive {:tackle_session_title_changed, _sid, _title}, 300
    end
  end

  defp root_opts(opts \\ []) do
    defaults = [
      session_titles: [model: "test/echo"],
      content: "Fix the login form"
    ]

    Keyword.merge(defaults, opts)
  end

  defp title_call?(opts) do
    opts
    |> Keyword.get(:messages, [])
    |> List.first()
    |> Map.get(:content, "")
    |> String.contains?("Generate a concise, single-line task title")
  end
end
