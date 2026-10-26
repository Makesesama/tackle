defmodule Tackle.Lib.EventTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Event
  alias Tackle.Lib.Usage

  describe "auxiliary?/1" do
    test "is true only for events whose data carries auxiliary: true" do
      assert Event.auxiliary?(Event.new(:narration, %{text: "reading", auxiliary: true}))
      refute Event.auxiliary?(Event.new(:narration, %{text: "reading"}))
      refute Event.auxiliary?(Event.new(:narration, %{auxiliary: "yes"}))
      refute Event.auxiliary?(Event.new(:tool_start))
    end
  end

  describe "normalize/2" do
    test "keeps Tackle.Lib events unchanged" do
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

    test "normalizes events without a type into provider events" do
      assert %Event{type: :provider_event, data: data} = Event.normalize(%{note: "hi"})
      assert data == %{note: "hi"}
    end

    test "keeps the type of an unrecognized string-typed provider event" do
      assert %Event{type: :provider_event, data: %{provider_type: "ping", seq: 1}} =
               Event.normalize(%{"type" => "ping", seq: 1})
    end
  end
end
