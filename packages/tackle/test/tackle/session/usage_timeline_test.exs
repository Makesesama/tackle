defmodule Tackle.Session.UsageTimelineTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Usage
  alias Tackle.Session.Projection
  alias Tackle.Session.UsageTimeline

  test "projects settled assistant usage in UTC timestamp order" do
    projection = %Projection{
      session_id: "session-1",
      messages: [
        message("later", "2026-01-02T10:00:00+02:00", %{
          "input_tokens" => 4,
          "cache_read_tokens" => 6,
          "output_tokens" => 2
        }),
        %{"id" => "user", "role" => "user", "timestamp" => "2026-01-01T00:00:00Z"},
        message("earlier", "2026-01-01T08:00:00Z", %{input_tokens: 3, output_tokens: 1})
      ]
    }

    timeline = UsageTimeline.from_projection(projection)

    assert Enum.map(timeline.samples, & &1.message_id) == ["earlier", "later"]
    assert Enum.all?(timeline.samples, &(&1.timestamp.time_zone == "Etc/UTC"))
    assert timeline.session_count == 1
    assert timeline.skipped_sample_count == 0

    assert %Usage{input_tokens: 7, cache_read_tokens: 6, output_tokens: 3, total_tokens: 16} =
             timeline.usage
  end

  test "skips assistant records without a timestamp or chartable total" do
    projection = %Projection{
      session_id: "session-1",
      messages: [
        message("missing-time", nil, %{input_tokens: 2}),
        message("missing-usage", "2026-01-01T00:00:00Z", nil),
        message("reasoning-only", "2026-01-01T00:00:00Z", %{reasoning_tokens: 3}),
        message("valid", "2026-01-01T00:00:00Z", %{total_tokens: 5})
      ]
    }

    timeline = UsageTimeline.from_projection(projection)

    assert Enum.map(timeline.samples, & &1.message_id) == ["valid"]
    assert timeline.skipped_sample_count == 3
  end

  test "calendar week starts Monday at midnight UTC and range filters are inclusive" do
    now = ~U[2026-09-13 23:30:00Z]
    assert UsageTimeline.calendar_week_start(now) == ~U[2026-09-07 00:00:00Z]

    projection = %Projection{
      session_id: "session-1",
      messages: [
        message("before", "2026-09-06T23:59:59Z", %{total_tokens: 2}),
        message("start", "2026-09-07T00:00:00Z", %{total_tokens: 3}),
        message("end", "2026-09-13T23:30:00Z", %{total_tokens: 5}),
        message("after", "2026-09-13T23:30:01Z", %{total_tokens: 7})
      ]
    }

    timeline =
      UsageTimeline.from_projection(projection,
        since: UsageTimeline.calendar_week_start(now),
        until: now
      )

    assert Enum.map(timeline.samples, & &1.message_id) == ["start", "end"]
    assert timeline.usage.total_tokens == 8
  end

  test "global merge deduplicates exact fork copies and retains id conflicts" do
    original =
      UsageTimeline.from_projection(%Projection{
        session_id: "parent",
        messages: [message("shared", "2026-01-01T00:00:00Z", %{total_tokens: 5})]
      })

    fork =
      UsageTimeline.from_projection(%Projection{
        session_id: "fork",
        messages: [
          message("shared", "2026-01-01T00:00:00Z", %{total_tokens: 5}),
          message("child", "2026-01-02T00:00:00Z", %{total_tokens: 7})
        ]
      })

    conflict =
      UsageTimeline.from_projection(%Projection{
        session_id: "other",
        messages: [message("shared", "2026-01-03T00:00:00Z", %{total_tokens: 11})]
      })

    timeline =
      UsageTimeline.merge([original, fork, conflict], [
        %{session_id: "bad", reason: :corrupt}
      ])

    assert Enum.map(timeline.samples, &{&1.session_id, &1.message_id}) == [
             {"parent", "shared"},
             {"fork", "child"},
             {"other", "shared"}
           ]

    assert timeline.usage.total_tokens == 23
    assert timeline.duplicate_sample_count == 1
    assert timeline.conflicting_sample_count == 1
    assert timeline.session_count == 3
    assert timeline.skipped_session_count == 1
  end

  test "messages without stable ids are never deduplicated" do
    one =
      UsageTimeline.from_projection(%Projection{
        session_id: "one",
        messages: [message(nil, "2026-01-01T00:00:00Z", %{total_tokens: 2})]
      })

    two =
      UsageTimeline.from_projection(%Projection{
        session_id: "two",
        messages: [message(nil, "2026-01-01T00:00:00Z", %{total_tokens: 2})]
      })

    timeline = UsageTimeline.merge([one, two])
    assert [_sample_one, _sample_two] = timeline.samples
    assert timeline.usage.total_tokens == 4
    assert timeline.duplicate_sample_count == 0
  end

  defp message(id, timestamp, usage) do
    %{
      "id" => id,
      "role" => "assistant",
      "timestamp" => timestamp,
      "token_usage" => usage
    }
  end
end
