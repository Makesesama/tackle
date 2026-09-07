defmodule Tackle.EventTest do
  use ExUnit.Case, async: true

  alias Tackle.Event
  alias Tackle.Usage

  describe "normalize/2" do
    test "keeps Tackle events unchanged" do
      event = Event.new(:step_start, %{iteration: 1})
      assert Event.normalize(event) == event
    end

    test "normalizes provider text chunks into message deltas" do
      assert %Event{type: :message_delta, data: %{delta: "hello"}, metadata: metadata} =
               Event.normalize(%{type: :text_delta, text: "hello"}, provider: :test_provider)

      assert metadata.provider == :test_provider
      assert metadata.raw.type == :text_delta
    end

    test "normalizes usage chunks into usage events" do
      assert %Event{type: :usage, data: %{usage: %Usage{input_tokens: 3, output_tokens: 2}}} =
               Event.normalize(%{type: :usage, usage: %{prompt_tokens: 3, completion_tokens: 2}})
    end

    test "normalizes reasoning and partial tool input as message deltas with fields" do
      assert %Event{type: :message_delta, data: %{field: :reasoning, delta: "thinking"}} =
               Event.normalize(%{type: :reasoning_delta, delta: "thinking"})

      assert %Event{
               type: :message_delta,
               data: %{
                 field: :tool_input,
                 tool_call_id: "call-1",
                 tool_name: "search",
                 delta: "{\"q"
               }
             } =
               Event.normalize(%{
                 type: :tool_input_delta,
                 tool_call_id: "call-1",
                 tool_name: "search",
                 delta: "{\"q"
               })
    end
  end
end
