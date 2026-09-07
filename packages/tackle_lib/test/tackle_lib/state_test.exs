defmodule Tackle.Lib.StateTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.LLM.Selection
  alias Tackle.Lib.Message
  alias Tackle.Lib.State
  alias Tackle.Lib.Usage

  describe "new/1" do
    test "creates a new state with defaults" do
      state = State.new()

      assert state.session_id != nil
      assert state.messages == []
      assert state.current_iteration == 0
      assert state.max_iterations == 10
      assert state.status == :idle
      # Tackle.Lib has no baked-in default model — the host supplies it.
      assert state.llm == nil
      assert state.model == nil
      assert state.tools == []
      assert is_function(state.id_generator, 0)
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
      assert state.tools == [SomeTool]
      assert state.id_generator.() == "custom-id"
    end

    test "accepts an explicit LLM selection and uses its adapter-local model" do
      selection = %Selection{
        adapter: ExampleAdapter,
        adapter_id: "example",
        model: "selected-model",
        ref: "example/selected-model"
      }

      state = State.new(llm: selection, model: "ignored-model")

      assert state.llm == selection
      assert state.model == "selected-model"
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

      assert length(state.messages) == 1
      assert hd(state.messages).content == "Hello"
    end
  end

  describe "set_status/2" do
    test "updates the status" do
      state = State.new()

      state = State.set_status(state, :thinking)
      assert state.status == :thinking

      state = State.set_status(state, :completed)
      assert state.status == :completed
    end
  end

  describe "increment_iteration/1" do
    test "increments the iteration counter" do
      state = State.new()

      state = State.increment_iteration(state)
      assert state.current_iteration == 1

      state = State.increment_iteration(state)
      assert state.current_iteration == 2
    end
  end

  describe "max_iterations_reached?/1" do
    test "returns false when under max" do
      state = State.new(max_iterations: 3)
      refute State.max_iterations_reached?(state)
    end

    test "returns true when at max" do
      state =
        State.new(max_iterations: 2)
        |> State.increment_iteration()
        |> State.increment_iteration()

      assert State.max_iterations_reached?(state)
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

  describe "set_error/2" do
    test "sets the error and status" do
      state = State.new()

      state = State.set_error(state, "Something went wrong")

      assert state.status == :error
      assert state.error == "Something went wrong"
    end
  end
end
