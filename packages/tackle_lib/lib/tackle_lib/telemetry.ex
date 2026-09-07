defmodule Tackle.Lib.Telemetry do
  @moduledoc """
  Small, exporter-neutral lifecycle telemetry helpers.

  Event metadata intentionally contains only correlation references and bounded
  classifications. Callers must never pass prompts, messages, tool arguments,
  tool results, or raw errors to these functions.
  """

  @type event_prefix :: [atom()]

  @spec start(event_prefix(), map()) :: reference()
  def start(event_prefix, metadata) when is_list(event_prefix) and is_map(metadata) do
    telemetry_ref = make_ref()

    :telemetry.execute(
      event_prefix ++ [:start],
      %{system_time: System.system_time()},
      Map.put(metadata, :telemetry_ref, telemetry_ref)
    )

    telemetry_ref
  end

  @spec stop(event_prefix(), reference(), map(), map()) :: :ok
  def stop(event_prefix, telemetry_ref, measurements, metadata)
      when is_list(event_prefix) and is_reference(telemetry_ref) and is_map(measurements) and
             is_map(metadata) do
    :telemetry.execute(
      event_prefix ++ [:stop],
      measurements,
      metadata |> Map.put(:telemetry_ref, telemetry_ref)
    )

    :ok
  end

  @spec exception(event_prefix(), reference(), map()) :: :ok
  def exception(event_prefix, telemetry_ref, metadata)
      when is_list(event_prefix) and is_reference(telemetry_ref) and is_map(metadata),
      do: exception(event_prefix, telemetry_ref, %{}, metadata)

  @spec exception(event_prefix(), reference(), map(), map()) :: :ok
  def exception(event_prefix, telemetry_ref, measurements, metadata)
      when is_list(event_prefix) and is_reference(telemetry_ref) and is_map(measurements) and
             is_map(metadata) do
    :telemetry.execute(
      event_prefix ++ [:exception],
      measurements,
      metadata |> Map.put(:telemetry_ref, telemetry_ref)
    )

    :ok
  end

  @spec monotonic_duration(integer()) :: integer()
  def monotonic_duration(start_time) when is_integer(start_time),
    do: System.monotonic_time() - start_time
end
