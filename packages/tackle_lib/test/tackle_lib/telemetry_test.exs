defmodule Tackle.Lib.TelemetryTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Telemetry

  @prefix [:tackle, :telemetry_test, :span]

  setup do
    handler_id = {__MODULE__, make_ref()}
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [@prefix ++ [:start], @prefix ++ [:stop], @prefix ++ [:exception]],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  test "emits balanced lifecycle metadata without caller payloads" do
    span = Telemetry.start(@prefix, %{tool_name: "safe_name"})
    ref = span.telemetry_ref

    assert_receive {:telemetry, [_, _, _, :start], %{system_time: _, monotonic_time: _}, start}
    assert start == %{telemetry_ref: ref, tool_name: "safe_name"}

    :ok = Telemetry.stop(span, %{count: 1}, %{outcome: :success})

    assert_receive {:telemetry, [_, _, _, :stop], %{duration: duration, count: 1}, stop}
    assert is_integer(duration) and duration >= 0

    # The stop event keeps the start metadata.
    assert stop == %{telemetry_ref: ref, tool_name: "safe_name", outcome: :success}
  end

  test "exception events carry the kind and the start metadata, never the raw reason" do
    span = Telemetry.start(@prefix, %{operation: :run})
    ref = span.telemetry_ref

    :ok = Telemetry.exception(span, :exit, %{count: 1}, %{error_type: :task_exit})

    assert_receive {:telemetry, [_, _, _, :exception], %{duration: duration, count: 1}, metadata}

    assert is_integer(duration)

    assert metadata == %{
             telemetry_ref: ref,
             operation: :run,
             kind: :exit,
             error_type: :task_exit
           }

    :ok = Telemetry.exception(span, :throw)

    assert_receive {:telemetry, [_, _, _, :exception], %{duration: _},
                    %{kind: :throw, operation: :run, telemetry_ref: ^ref}}

    assert_raise FunctionClauseError, fn -> Telemetry.exception(span, :oops) end
  end

  test "stop metadata overrides start metadata with the same key" do
    span = Telemetry.start(@prefix, %{outcome: :pending})
    :ok = Telemetry.stop(span, %{}, %{outcome: :done})

    assert_receive {:telemetry, [_, _, _, :stop], _measurements, %{outcome: :done}}
  end
end
