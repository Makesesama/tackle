defmodule Tackle.Lib.TelemetryTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Telemetry

  test "emits balanced lifecycle metadata without caller payloads" do
    handler_id = {__MODULE__, make_ref()}
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:tackle, :tool, :execution, :start], [:tackle, :tool, :execution, :stop]],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    try do
      ref = Telemetry.start([:tackle, :tool, :execution], %{tool_name: "safe_name"})
      assert_receive {:telemetry, [:tackle, :tool, :execution, :start], %{system_time: _}, start}
      assert start.telemetry_ref == ref
      assert start.tool_name == "safe_name"
      refute Map.has_key?(start, :arguments)
      refute Map.has_key?(start, :result)

      :ok =
        Telemetry.stop(
          [:tackle, :tool, :execution],
          ref,
          %{duration: 1, count: 1},
          %{tool_name: "safe_name", outcome: :success}
        )

      assert_receive {:telemetry, [:tackle, :tool, :execution, :stop], %{duration: 1, count: 1},
                      stop}

      assert stop.telemetry_ref == ref
      assert stop.outcome == :success
      refute Map.has_key?(stop, :raw)
    after
      :telemetry.detach(handler_id)
    end
  end
end
