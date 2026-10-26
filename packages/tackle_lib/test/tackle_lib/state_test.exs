defmodule Tackle.Lib.StateTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Compaction
  alias Tackle.Lib.Compaction.Checkpoint
  alias Tackle.Lib.Compaction.Record
  alias Tackle.Lib.LLM.Selection
  alias Tackle.Lib.Message
  alias Tackle.Lib.Retry
  alias Tackle.Lib.State
  alias Tackle.Lib.Tree
  alias Tackle.Lib.Usage

  defmodule SomeTool do
    @behaviour Tackle.Lib.Tool

    @impl true
    def name, do: "some_tool"

    @impl true
    def description, do: "A state test tool."

    @impl true
    def parameters_schema, do: []

    @impl true
    def execute(_args, _context), do: {:ok, "ok"}
  end

  defmodule AnotherTool do
    @behaviour Tackle.Lib.Tool

    @impl true
    def name, do: "another_tool"

    @impl true
    def description, do: "Another state test tool."

    @impl true
    def parameters_schema, do: []

    @impl true
    def execute(_args, _context), do: {:ok, "ok"}
  end

  defmodule SomeHook do
    @behaviour Tackle.Lib.Hook

    @impl true
    def before_tool_call(_state, _call, _context), do: :ok
  end

  describe "new/1" do
    test "rejects options it does not know" do
      assert_raise ArgumentError, ~r/unknown keys \[:prompt_renderer\]/, fn ->
        State.new(prompt_renderer: SomeRenderer)
      end
    end

    test "creates a new state with defaults" do
      state = State.new()

      assert state.session_id != nil
      assert state.messages == []
      assert state.model_messages == []
      assert Tree.empty?(state.tree)
      assert state.current_iteration == 0
      assert state.max_iterations == :infinity
      assert state.status == :idle
      # Tackle.Lib has no baked-in default model — the host supplies it.
      assert state.llm == nil
      assert State.model(state) == nil
      assert State.tools(state) == []
      assert state.retry == Retry.new!()
      assert is_function(state.id_generator, 0)
    end

    test "validates retry options" do
      assert State.new(retry: false).retry.enabled? == false
      assert State.new(retry: [max_retries: 1]).retry.max_retries == 1

      assert_raise ArgumentError, ~r/invalid :retry config/, fn ->
        State.new(retry: [base_delay_ms: -1])
      end
    end

    test "compaction is a config or nil, which disables it" do
      assert State.new().compaction == nil
      assert State.new(compaction: nil).compaction == nil
      assert %Compaction.Config{max_passes: 2} = State.new(compaction: [max_passes: 2]).compaction

      config = Compaction.Config.new!([])
      assert State.new(compaction: config).compaction == config

      for value <- [false, true] do
        assert_raise ArgumentError, ~r/expected :compaction/, fn ->
          State.new(compaction: value)
        end
      end

      # Durability belongs to the state's committer, and nil is the only way
      # to disable compaction.
      for option <- [committer: MyCommitter, enabled?: false] do
        assert_raise ArgumentError, ~r/unknown_options/, fn ->
          State.new(compaction: [option])
        end
      end
    end

    test "accepts custom options" do
      state =
        State.new(
          max_iterations: 5,
          tools: [SomeTool],
          id_generator: fn -> "custom-id" end
        )

      assert state.session_id == "custom-id"
      assert state.max_iterations == 5
      assert State.tools(state) == [SomeTool]
      assert state.id_generator.() == "custom-id"
    end

    test "rejects invalid tool configuration before creating a usable state" do
      assert_raise ArgumentError, ~r/not a valid Tackle.Lib.Tool/, fn ->
        State.new(tools: [SomeTool, :missing_tool_module])
      end

      assert_raise ArgumentError, ~r/duplicate tool name/, fn ->
        State.new(tools: [SomeTool, SomeTool])
      end
    end

    test "accepts hook modules and rejects entries that would never run" do
      assert State.new(hooks: [SomeHook]).hooks == [SomeHook]

      # A misspelled gate used to skip every callback silently, and a
      # non-module entry crashed the loop outside the hook's error handling.
      for invalid <- [Tackle.Lib.StateTest.SomeHok, SomeTool, "SomeHook"] do
        assert_raise ArgumentError, ~r/Tackle.Lib.Hook callback, got invalid entries/, fn ->
          State.new(hooks: [SomeHook, invalid])
        end
      end

      assert_raise ArgumentError, ~r/expected :hooks to be a list/, fn ->
        State.new(hooks: SomeHook)
      end
    end

    test "accepts an existing session id without invoking the id generator" do
      state =
        State.new(
          session_id: "persisted-session",
          id_generator: fn -> flunk("id generator should not be invoked") end
        )

      assert state.session_id == "persisted-session"
    end

    test "accepts an explicit LLM selection and uses its adapter-local model" do
      selection = %Selection{
        adapter: ExampleAdapter,
        provider_id: "example",
        model: "selected-model",
        ref: "example/selected-model"
      }

      state = State.new(llm: selection)

      assert state.llm == selection
      assert State.model(state) == "selected-model"
      assert State.model(%{state | llm: %{selection | model: "swapped"}}) == "swapped"
    end

    test "takes the model only from the selection" do
      selection = %Selection{
        adapter: ExampleAdapter,
        provider_id: "example",
        model: "selected-model",
        ref: "example/selected-model"
      }

      for opts <- [[llm: selection, model: "other-model"], [model: "plain-model"]] do
        assert_raise ArgumentError, ~r/the model comes from the :llm selection/, fn ->
          State.new(opts)
        end
      end
    end

    test "rejects an invalid LLM selection" do
      assert_raise ArgumentError, ~r/expected :llm to be/, fn ->
        State.new(llm: ExampleAdapter)
      end
    end
  end

  describe "add_message/2" do
    test "appends the message to the tree, the transcript, and the model context" do
      message = Message.user("Hello")
      state = State.add_message(State.new(), message)

      assert state.messages == [message]
      assert state.model_messages == [message]
      assert Tree.active_id(state.tree) == message.id
      assert Tree.transcript(state.tree) == [message]
    end

    test "raises for a message the tree refuses" do
      message = Message.user("Hello")
      state = State.add_message(State.new(), message)

      assert_raise ArgumentError, ~r/duplicate_entry/, fn -> State.add_message(state, message) end
    end
  end

  describe "put_tree/2 and the :tree option" do
    test "install a tree and derive the transcript and model context from it" do
      user = Message.user("Hello", id: "u1")
      answer = Message.assistant(content: "Hi", id: "a1")
      tree = State.new() |> State.add_message(user) |> State.add_message(answer) |> Map.get(:tree)
      {:ok, tree, _entry} = Tree.append_compaction(tree, record("c1", ["u1"], "a1"))

      for state <- [State.put_tree(State.new(), tree), State.new(tree: tree)] do
        assert state.tree == tree
        assert state.messages == [user, answer]
        assert state.model_messages == Tree.model_context(tree)
        assert [%Message{id: "c1"}, %Message{id: "a1"}] = state.model_messages
      end
    end

    test "rejects anything but a tree" do
      for value <- [true, false, [], %{}] do
        assert_raise ArgumentError, ~r/expected :tree to be a Tackle.Lib.Tree/, fn ->
          State.new(tree: value)
        end
      end
    end
  end

  describe "update_message/3" do
    test "replaces a message in the tree, the transcript, and the model context" do
      user = Message.user("Hello", id: "u1")
      answer = Message.assistant(content: "Hi", id: "a1")
      state = State.new() |> State.add_message(user) |> State.add_message(answer)
      usage = %Usage{input_tokens: 3, output_tokens: 1}

      assert {:ok, updated} = State.update_message(state, "a1", &%{&1 | token_usage: usage})

      assert [^user, %Message{id: "a1", token_usage: ^usage}] = updated.messages
      assert updated.model_messages == updated.messages
      assert Tree.transcript(updated.tree) == updated.messages
      assert Tree.active_id(updated.tree) == "a1"
      assert State.usage(updated).input_tokens == 3
    end

    test "keeps message ids and reports unknown ones" do
      state = State.add_message(State.new(), Message.user("Hello", id: "u1"))

      assert State.update_message(state, "missing", & &1) ==
               {:error, {:unknown_message, "missing"}}

      assert_raise ArgumentError, ~r/same id/, fn ->
        State.update_message(state, "u1", &%{&1 | id: "other"})
      end
    end
  end

  describe "tools/1" do
    test "returns the configured tools in their given order" do
      assert State.tools(State.new(tools: [SomeTool, AnotherTool])) == [SomeTool, AnotherTool]
      assert State.tools(State.new(tools: [AnotherTool, SomeTool])) == [AnotherTool, SomeTool]
    end
  end

  describe "reset_turn/1" do
    test "clears the per-turn fields and keeps the conversation" do
      state =
        State.new(max_iterations: 3)
        |> State.add_message(Message.user("Hello"))
        |> Map.put(:current_iteration, 3)
        |> State.set_error("Failed", :timeout)

      reset = State.reset_turn(state)

      assert reset.current_iteration == 0
      assert reset.status == :idle
      assert reset.error == nil
      assert reset.error_reason == nil
      assert reset.messages == state.messages
      assert reset.max_iterations == 3
    end
  end

  describe "last_compaction/1 and last_compaction_id/1" do
    test "are nil before any compaction" do
      assert State.last_compaction(State.new()) == nil
      assert State.last_compaction_id(State.new()) == nil

      state = State.add_message(State.new(), Message.user("Hello"))
      assert State.last_compaction(state) == nil
      assert State.last_compaction_id(state) == nil
    end

    test "are the latest compaction on the active path" do
      first = record("c1", ["u1"], "a1")
      second = %{record("c2", ["c1", "a1"], "u2") | previous_compaction_id: "c1"}

      state =
        State.new()
        |> State.add_message(Message.user("Hello", id: "u1"))
        |> State.add_message(Message.assistant(content: "Hi", id: "a1"))
        |> compact(first)
        |> State.add_message(Message.user("Next", id: "u2"))
        |> compact(second)

      assert %Record{compaction_id: "c2"} = State.last_compaction(state)
      assert State.last_compaction_id(state) == "c2"
      assert hd(state.model_messages) == State.last_compaction(state).summary_message
    end

    test "a user message that reads like a checkpoint is not one" do
      lookalike = Checkpoint.message("u1", "Earlier work")

      state =
        State.new() |> State.add_message(lookalike) |> State.add_message(Message.user("Next"))

      assert State.last_compaction(state) == nil
      assert State.last_compaction_id(state) == nil
      assert State.usage_segments(state) == [[]]
    end
  end

  describe "usage_segments/1" do
    test "returns one span without a compaction" do
      first = Message.assistant(content: "a", token_usage: %Usage{input_tokens: 1})
      second = Message.assistant(content: "b", token_usage: %Usage{input_tokens: 2})

      state =
        State.new()
        |> State.add_message(Message.user("q"))
        |> State.add_message(first)
        |> State.add_message(second)

      assert State.usage_segments(state) == [[first.token_usage, second.token_usage]]
      assert State.usage_segments(State.new()) == [[]]
    end

    test "starts a span after the latest compaction" do
      before = Message.assistant(content: "a", id: "a1", token_usage: %Usage{input_tokens: 1})
      retained = Message.assistant(content: "b", id: "a2", token_usage: %Usage{input_tokens: 2})
      later = Message.assistant(content: "c", id: "a3", token_usage: %Usage{input_tokens: 3})

      state =
        State.new()
        |> State.add_message(before)
        |> State.add_message(retained)
        |> compact(record("c1", ["a1"], "a2"))
        |> State.add_message(later)

      assert state.model_messages == [
               State.last_compaction(state).summary_message,
               %{retained | token_usage: nil},
               later
             ]

      assert State.usage_segments(state) == [
               [before.token_usage, retained.token_usage],
               [later.token_usage]
             ]
    end

    test "keeps the current span right after a compaction, while it has no usage" do
      before = Message.assistant(content: "a", id: "a1", token_usage: %Usage{input_tokens: 1})
      state = State.new() |> State.add_message(before) |> compact(record("c1", ["a1"], nil))

      assert State.usage_segments(state) == [[before.token_usage], []]
    end
  end

  describe "max_iterations_reached?/1" do
    test "returns false when the default limit is unlimited" do
      refute State.max_iterations_reached?(%{State.new() | current_iteration: 20})
    end

    test "returns false when under an explicit max" do
      state = State.new(max_iterations: 3)
      refute State.max_iterations_reached?(state)
    end

    test "returns true when at an explicit max" do
      assert State.max_iterations_reached?(%{State.new(max_iterations: 2) | current_iteration: 2})
    end
  end

  describe "usage/1" do
    test "derives aggregate usage from message usage" do
      state =
        State.new()
        |> State.add_message(Message.user("Hello"))
        |> State.add_message(
          Message.assistant(
            content: "Need a tool",
            token_usage: %Usage{input_tokens: 10, output_tokens: 5, cost: 0.01, currency: "USD"}
          )
        )
        |> State.add_message(
          Message.assistant(
            content: "Done",
            token_usage: %Usage{input_tokens: 7, output_tokens: 3, cost: 0.02, currency: "USD"}
          )
        )

      usage = State.usage(state)

      assert usage.input_tokens == 17
      assert usage.output_tokens == 8
      assert usage.total_tokens == 25
      assert_in_delta usage.cost, 0.03, 0.000_001
      assert usage.currency == "USD"
    end
  end

  describe "set_error/3" do
    test "sets the error and status" do
      state = State.new()

      state = State.set_error(state, "Something went wrong")

      assert state.status == :error
      assert state.error == "Something went wrong"
      assert state.error_reason == nil
    end

    test "keeps the structured reason next to the message" do
      state = State.set_error(State.new(), "Failed to get response: :timeout", :timeout)

      assert state.error == "Failed to get response: :timeout"
      assert state.error_reason == :timeout
    end

    test "cancelling clears the error reason" do
      state =
        State.new()
        |> State.set_error("Failed", :timeout)
        |> State.set_cancelled("stop")

      assert state.status == :cancelled
      assert state.error == "stop"
      assert state.error_reason == nil
    end
  end

  defp compact(state, record) do
    {:ok, tree, _entry} = Tree.append_compaction(state.tree, record)
    State.put_tree(state, tree)
  end

  defp record(id, shadowed, first_retained) do
    %Record{
      compaction_id: id,
      trigger: :manual,
      summary_message: Checkpoint.message(id, "Earlier work"),
      shadowed_message_ids: shadowed,
      first_retained_message_id: first_retained,
      tokens_before: 100,
      estimated_tokens_after: 10,
      created_at: ~U[2026-01-01 00:00:00Z]
    }
  end
end
