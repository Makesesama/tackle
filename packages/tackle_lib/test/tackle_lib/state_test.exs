defmodule Tackle.Lib.StateTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Compaction
  alias Tackle.Lib.LLM.Selection
  alias Tackle.Lib.Message
  alias Tackle.Lib.Retry
  alias Tackle.Lib.State
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
    test "creates a new state with defaults" do
      state = State.new()

      assert state.session_id != nil
      assert state.messages == []
      assert state.current_iteration == 0
      assert state.max_iterations == :infinity
      assert state.status == :idle
      # Tackle.Lib has no baked-in default model — the host supplies it.
      assert state.llm == nil
      assert state.model == nil
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

    test "accepts custom options" do
      state =
        State.new(
          model: "custom/model",
          max_iterations: 5,
          tools: [SomeTool],
          id_generator: fn -> "custom-id" end
        )

      assert state.session_id == "custom-id"
      assert state.model == "custom/model"
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
      assert state.model == "selected-model"
    end

    test "rejects a model next to an LLM selection" do
      selection = %Selection{
        adapter: ExampleAdapter,
        provider_id: "example",
        model: "selected-model",
        ref: "example/selected-model"
      }

      assert_raise ArgumentError, ~r/either :llm or :model, not both/, fn ->
        State.new(llm: selection, model: "other-model")
      end
    end

    test "rejects an invalid LLM selection" do
      assert_raise ArgumentError, ~r/expected :llm to be/, fn ->
        State.new(llm: ExampleAdapter)
      end
    end
  end

  describe "add_message/2" do
    test "adds a message to the state" do
      state = State.new()
      message = Message.user("Hello")

      state = State.add_message(state, message)

      assert [_message] = state.messages
      assert hd(state.messages).content == "Hello"
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

  describe "last_compaction_id/1" do
    test "is nil before any compaction" do
      assert State.last_compaction_id(State.new()) == nil

      state = State.add_message(State.new(), Message.user("Hello"))
      assert State.last_compaction_id(%{state | model_messages: state.messages}) == nil
    end

    test "is the id of the checkpoint at the head of a linear model projection" do
      checkpoint = Compaction.checkpoint_message("compaction-1", "Earlier work")
      state = %{State.new() | model_messages: [checkpoint, Message.user("Next")]}

      assert State.last_compaction_id(state) == "compaction-1"
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
      assert State.usage_segments(State.new()) == []
    end

    test "starts a span after the latest compaction of a linear projection" do
      before = Message.assistant(content: "a", token_usage: %Usage{input_tokens: 1})
      retained = Message.assistant(content: "b", token_usage: %Usage{input_tokens: 2})
      later = Message.assistant(content: "c", token_usage: %Usage{input_tokens: 3})
      checkpoint = Compaction.checkpoint_message("compaction-1", "Earlier work")

      state = %{
        State.new()
        | messages: [before, retained, later],
          model_messages: [checkpoint, %{retained | token_usage: nil}, later]
      }

      assert State.usage_segments(state) == [
               [before.token_usage, retained.token_usage],
               [later.token_usage]
             ]
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
      assert Tackle.Lib.usage(state) == usage
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
end
