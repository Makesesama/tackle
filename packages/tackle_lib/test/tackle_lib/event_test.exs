defmodule Tackle.Lib.EventTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Event
  alias Tackle.Lib.LLM.Response
  alias Tackle.Lib.Tool.Call
  alias Tackle.Lib.Tool.Error, as: ToolError
  alias Tackle.Lib.Tool.Result, as: ToolResult
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

    test "passes host event atoms through and treats host type strings as provider events" do
      assert %Event{type: :subagent_progress, data: %{run_id: "r1"}} =
               Event.normalize(%{type: :subagent_progress, run_id: "r1"})

      assert %Event{type: :provider_event, data: %{provider_type: "subagent_progress"}} =
               Event.normalize(%{"type" => "subagent_progress"})
    end

    test "builds provider errors with the error event's payload" do
      assert %Event{type: :error, data: %{error: "boom", reason: nil}} =
               Event.normalize(%{type: :provider_error, message: "boom"})
    end
  end

  describe "turn and step constructors" do
    test "build one payload per event type" do
      assert %Event{type: :turn_start, data: %{session_id: "s1"}} = Event.turn_start("s1")

      assert %Event{type: :turn_end, data: %{session_id: "s1", status: :error}} =
               Event.turn_end("s1", :error)

      assert %Event{type: :turn_cancelled, data: %{session_id: "s1", reason: "stop"}} =
               Event.turn_cancelled("s1", "stop")

      assert %Event{type: :status_change, data: %{status: :thinking}} =
               Event.status_change(:thinking)

      assert %Event{type: :step_start, data: %{iteration: 2}} = Event.step_start(2)
    end

    test "step_end/3 reports the kept response's usage, model, and provider" do
      usage = Usage.normalize(%{input_tokens: 3, output_tokens: 2})
      response = %Response{content: "hi", usage: usage, model: "m", provider: "p"}

      assert Event.step_end(1, response).data == %{
               iteration: 1,
               usage: usage,
               model: "m",
               provider: "p"
             }
    end

    test "error/3 always carries a reason" do
      assert Event.error("Failed", :timeout).data == %{error: "Failed", reason: :timeout}
      assert Event.error("Failed", nil).data == %{error: "Failed", reason: nil}
    end

    test "accept the event options of new/3" do
      timestamp = ~U[2026-01-01 00:00:00Z]

      assert %Event{id: "e1", parent_id: "p1", timestamp: ^timestamp, metadata: %{a: 1}} =
               Event.turn_start("s1",
                 id: "e1",
                 parent_id: "p1",
                 timestamp: timestamp,
                 metadata: %{a: 1}
               )
    end
  end

  describe "tool constructors" do
    @call %Call{id: "c1", name: "lookup", arguments: %{"q" => "x"}}

    test "tool_start/2 reports the call" do
      assert Event.tool_start(@call).data == %{
               tool_call_id: "c1",
               name: "lookup",
               arguments: %{"q" => "x"}
             }
    end

    test "tool_end/2 reports the recorded result" do
      result = %ToolResult{
        tool_call_id: "c1",
        name: "lookup",
        raw: %{hits: 1},
        content: "1 hit",
        metadata: %{cached: true}
      }

      assert %Event{type: :tool_end, data: data} = Event.tool_end(result)

      assert data == %{
               tool_call_id: "c1",
               name: "lookup",
               result: "1 hit",
               raw: %{hits: 1},
               metadata: %{cached: true}
             }
    end

    test "tool_error/2 has one shape for failed and interrupted calls" do
      failed = %{ToolError.crashed(@call, :error, %RuntimeError{message: "boom"}) | name: nil}
      interrupted = ToolError.interrupted("c2", "lookup", :cancelled)

      for error <- [failed, interrupted] do
        assert %Event{type: :tool_error, data: data} = Event.tool_error(error)

        assert Map.keys(data) |> Enum.sort() ==
                 [:details, :error, :metadata, :name, :reason, :tool_call_id]
      end

      assert %{name: "unknown", reason: :execution_error, details: {:error, _}} =
               Event.tool_error(failed).data

      assert Event.tool_error(interrupted).data == %{
               tool_call_id: "c2",
               name: "lookup",
               error: "Tool execution was cancelled before this call completed.",
               reason: :interrupted,
               details: nil,
               metadata: %{}
             }
    end

    test "tool_execution_end/2 has one shape for both settlements" do
      result = %ToolResult{tool_call_id: "c1", name: "lookup", content: "1 hit"}
      error = ToolError.unknown_tool(@call)

      assert Event.tool_execution_end({:ok, result}).data == %{
               tool_call_id: "c1",
               name: "lookup",
               status: :completed,
               result: "1 hit",
               error: nil,
               reason: nil
             }

      assert Event.tool_execution_end({:error, error}).data == %{
               tool_call_id: "c1",
               name: "lookup",
               status: :failed,
               result: nil,
               error: "Unknown tool: lookup",
               reason: :unknown_tool
             }
    end
  end

  describe "retry constructors" do
    test "carry the message id and always a reason on retry_end" do
      assert %Event{id: "m1", data: data} = Event.retry_scheduled(1, 3, 2_000, :timeout, id: "m1")
      assert data == %{attempt: 1, max_retries: 3, delay_ms: 2_000, reason: :timeout}

      assert %Event{type: :retry_start, id: "m1", data: %{attempt: 1}} =
               Event.retry_start(1, id: "m1")

      assert %Event{type: :retry_end, id: "m1", data: data} =
               Event.retry_end(1, true, nil, id: "m1")

      assert data == %{attempt: 1, success?: true, reason: nil}
      assert Event.retry_end(2, false, :timeout).data.reason == :timeout
    end
  end

  describe "compaction constructors" do
    test "compaction_end/2 has every field, nil when not given" do
      event = Event.compaction_end(compaction_id: "c1", trigger: :manual, status: :failed)

      assert event.type == :compaction_end

      assert event.data == %{
               compaction_id: "c1",
               trigger: :manual,
               status: :failed,
               pass: nil,
               tokens_before: nil,
               estimated_tokens_after: nil,
               retained_count: nil,
               shadowed_count: nil,
               duration: nil,
               summary_model: nil,
               summary_usage: nil,
               error: nil
             }
    end

    test "compaction_start/2 and compaction_retry/3" do
      assert Event.compaction_start(compaction_id: "c1", trigger: :pressure, pass: 1).data ==
               %{compaction_id: "c1", trigger: :pressure, pass: 1, tokens_before: nil}

      assert %Event{type: :compaction_retry, data: %{trigger: :overflow, reason: :too_long}} =
               Event.compaction_retry(:overflow, :too_long)
    end

    test "reject unknown fields" do
      assert_raise ArgumentError, fn -> Event.compaction_start(summary: "secret") end
    end
  end
end
