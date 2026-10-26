defmodule Tackle.Session.EventsTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.ContextUsage
  alias Tackle.Lib.Event
  alias Tackle.Lib.LLM.Selection
  alias Tackle.Lib.ModelInfo
  alias Tackle.Lib.State, as: AgentState
  alias Tackle.Lib.Usage
  alias Tackle.Session.Events

  # A process that stays alive until the test ends.
  defp subscriber, do: spawn_link(fn -> Process.sleep(:infinity) end)

  test "subscribing twice keeps one monitored subscription" do
    events = Events.new("session") |> Events.subscribe(self()) |> Events.subscribe(self())

    assert map_size(events.subscribers) == 1
    Events.title_changed(events, "Fix it")
    assert_received {:tackle_session_title_changed, "session", "Fix it"}
    refute_received {:tackle_session_title_changed, "session", "Fix it"}
  end

  test "unsubscribing stops deliveries and its monitor" do
    pid = subscriber()
    events = Events.new("session") |> Events.subscribe(self()) |> Events.subscribe(pid)
    %{^pid => monitor} = events.subscribers
    events = events |> Events.unsubscribe(pid) |> Events.unsubscribe(self())

    assert events.subscribers == %{}
    assert Events.unsubscribe(events, pid) == events

    Events.title_changed(events, "Fix it")
    refute_received {:tackle_session_title_changed, "session", _title}

    Process.unlink(pid)
    Process.exit(pid, :kill)
    refute_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 50
  end

  test "a subscriber's DOWN drops it; another monitor's does not" do
    pid = subscriber()
    events = Events.subscribe(Events.new("session"), pid)
    %{^pid => monitor} = events.subscribers

    assert Events.down(events, pid, make_ref()) == events
    assert Events.down(events, self(), monitor) == events
    assert Events.down(events, pid, monitor).subscribers == %{}
  end

  test "messages carry the session id" do
    events = Events.subscribe(Events.new("session"), self())
    event = Event.new(:compaction_start, %{trigger: :manual})
    state = AgentState.new()

    Events.event(events, nil, event)
    Events.event(events, "turn", event)
    Events.turn_started(events, "turn", :queued_messages)
    Events.turn_finished(events, "turn", {:ok, state})
    Events.turn_failed(events, "turn", :crashed)
    Events.reconfigured(events, :snapshot)
    Events.compacted(events, :snapshot, nil)
    Events.navigated(events, :snapshot, :outcome)
    Events.storage(events, :delayed)

    assert_received {:tackle_event, "session", nil, ^event}
    assert_received {:tackle_event, "session", "turn", ^event}
    assert_received {:tackle_turn_started, "session", "turn", :queued_messages}
    assert_received {:tackle_turn_finished, "session", "turn", {:ok, ^state}}
    assert_received {:tackle_turn_failed, "session", "turn", :crashed}
    assert_received {:tackle_session_reconfigured, "session", :snapshot}
    assert_received {:tackle_session_compacted, "session", :snapshot, nil}
    assert_received {:tackle_session_navigated, "session", :snapshot, :outcome}
    assert_received {:tackle_storage, "session", :delayed}
  end

  describe "project_usage/2" do
    setup do
      info = %ModelInfo{model: "echo", context_window: 1_000}

      llm = %Selection{
        adapter: __MODULE__,
        provider_id: "test",
        model: "echo",
        ref: "test/echo",
        model_info: info
      }

      {:ok, info: info, state: %{AgentState.new() | llm: llm}}
    end

    test "adds the selected model's metadata and context pressure", ctx do
      usage = %Usage{input_tokens: 400, output_tokens: 100}
      event = Events.project_usage(Event.usage(usage), ctx.state)

      assert event.data.model_info == ctx.info
      assert event.data.context_usage == ContextUsage.from_usage(event.data.usage, ctx.info)
      assert %ContextUsage{context_window: 1_000} = event.data.context_usage
    end

    test "keeps the metadata an event carries and computes pressure from it", ctx do
      info = %ModelInfo{model: "other", context_window: 2_000}
      usage = Event.usage(%Usage{input_tokens: 400, output_tokens: 100})

      event =
        Events.project_usage(%{usage | data: Map.put(usage.data, :model_info, info)}, ctx.state)

      assert event.data.model_info == info
      assert %ContextUsage{context_window: 2_000} = event.data.context_usage
    end

    test "leaves usage without a selection and other events as they are", ctx do
      usage = Event.usage(%Usage{input_tokens: 400, output_tokens: 100})
      event = Events.project_usage(usage, AgentState.new())

      assert event.data.model_info == nil
      assert event.data.context_usage == nil

      other = Event.new(:compaction_start, %{})
      assert Events.project_usage(other, ctx.state) == other
    end
  end
end
