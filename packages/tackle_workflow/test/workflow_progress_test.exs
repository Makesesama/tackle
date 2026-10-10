defmodule Tackle.Workflow.ProgressTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Tackle.Workflow.TestSupport

  alias Tackle.Lib.Event
  alias Tackle.Runtime.RunRef
  alias Tackle.Workflow
  alias Tackle.Workflow.Progress
  alias Tackle.Workflow.Tool, as: WorkflowTool

  @workflow_timeout 5_000

  defp observe(test_pid \\ self()), do: fn event -> send(test_pid, {:progress, event}) end

  defp drain(acc \\ []) do
    receive do
      {:progress, event} -> drain([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "sequential runs report their start, outcome, and the workflow's logs in order" do
    scope =
      start_scope(profiles: %{"scout" => agent_spec("scout"), "worker" => agent_spec("worker")})

    script = """
    local findings = tackle.await(tackle.spawn("scout", "map"))
    tackle.log("mapped")
    return tackle.await(tackle.spawn("worker", "do: " .. findings.text)).text
    """

    assert {:ok, ref} = Workflow.run(handle(scope), script, on_event: observe())
    assert {:ok, ["do: map"]} = Workflow.await(ref, @workflow_timeout)

    events = drain()

    assert [
             %{type: :run_started, run_id: scout, profile: "scout", prompt: "map", parallel: nil},
             %{type: :run_finished, run_id: scout, status: :ok, ok: true},
             %{type: :log, message: "mapped"},
             %{type: :run_started, run_id: worker, profile: "worker", prompt: "do: map"},
             %{type: :run_finished, run_id: worker, status: :ok, ok: true}
           ] = Enum.reject(events, &(&1.type == :run_event))

    assert scout != worker
  end

  test "spawn and fan-out items can choose the model of their run" do
    scope = start_scope(profiles: %{"scout" => agent_spec("scout")})

    script = """
    local single = tackle.await(tackle.spawn("scout", "one", {model = "test/fast"}))
    local default = tackle.await(tackle.spawn("scout", "two", nil))
    local items = tackle.parallel({"a", "b"}, function(item)
      if item == "a" then return "scout", item, {model = "test/strong"} end
      return "scout", item
    end)
    return single.text, default.text, items[1].text, items[2].text
    """

    assert {:ok, ref} = Workflow.run(handle(scope), script, on_event: observe())
    assert {:ok, ["one", "two", "a", "b"]} = Workflow.await(ref, @workflow_timeout)

    models =
      for %{type: :run_started, prompt: prompt, model: model} <- drain(),
          into: %{},
          do: {prompt, model}

    assert models == %{
             "one" => "test/fast",
             "two" => "test/echo",
             "a" => "test/strong",
             "b" => "test/echo"
           }
  end

  test "invalid or unavailable models are refused like other spawn failures" do
    scope = start_scope(profiles: %{"scout" => agent_spec("scout")})

    script = """
    local function try(opts)
      local ok, err = pcall(function() return tackle.spawn("scout", "go", opts) end)
      return tostring(err)
    end

    local items = tackle.parallel({1, 2, 3}, function(item)
      if item == 1 then return "scout", "x", {model = "other/model"} end
      if item == 2 then return "scout", "x", {model = ""} end
      return "scout", "x", {temperature = 1}
    end)

    return try({model = "other/model"}), try({model = 3}), try({colour = "red"}), try("test/x"),
      items[1].status .. ": " .. items[1].text,
      items[2].status .. ": " .. items[2].text,
      items[3].status .. ": " .. items[3].text
    """

    assert {:ok, ref} = Workflow.run(handle(scope), script)

    assert {:ok, [unavailable, bad_type, unknown_key, not_table, item1, item2, item3]} =
             Workflow.await(ref, @workflow_timeout)

    assert unavailable =~ "spawn failed: {:unknown_model, \"other/model\"}"
    assert bad_type =~ "spawn option model must be a non-empty string, got 3"
    assert unknown_key =~ "unknown spawn options: \"colour\""
    assert not_table =~ "spawn options must be a table, got string"
    assert item1 =~ "spawn_error: spawn failed: {:unknown_model, \"other/model\"}"
    assert item2 =~ "callback_error: spawn option model must be a non-empty string"
    assert item3 =~ "callback_error: unknown spawn options: \"temperature\""
  end

  test "an observed workflow reports its logs as progress" do
    scope = start_scope(profiles: %{})
    test_pid = self()

    assert {:ok, ref} =
             Workflow.run(handle(scope), ~s|tackle.log("noted")|,
               on_event: observe(),
               log: fn message -> send(test_pid, {:log, message}) end
             )

    assert {:ok, []} = Workflow.await(ref, @workflow_timeout)
    assert [%{type: :log, message: "noted"}] = drain()
    # The host's log callback is unaffected by observation.
    assert_receive {:log, "noted"}, 1_000
  end

  test "a fan-out reports its bounds, each item's run, and items that never ran" do
    scope = start_scope(profiles: %{"researcher" => agent_spec("researcher")})

    script = """
    return #tackle.parallel({"a", "b", "c"}, function(item, index)
      if index == 2 then return "nobody", item end
      return "researcher", item
    end, {limit = 2})
    """

    assert {:ok, ref} =
             Workflow.run(handle(scope), script,
               profiles: ["researcher"],
               on_event: observe()
             )

    assert {:ok, [3]} = Workflow.await(ref, @workflow_timeout)

    events = Enum.reject(drain(), &(&1.type == :run_event))

    assert [%{type: :parallel_started, id: id, count: 3, limit: 2} | _] = events
    assert %{type: :parallel_finished, id: ^id} = List.last(events)

    started = for %{type: :run_started} = event <- events, do: event

    assert [
             %{profile: "researcher", prompt: "a", parallel: %{id: ^id, index: 1}},
             %{profile: "researcher", prompt: "c", parallel: %{id: ^id, index: 3}}
           ] = started

    finished = for %{type: :run_finished} = event <- events, into: %{}, do: {event.run_id, event}

    for %{run_id: run_id} <- started do
      assert %{profile: "researcher", status: :ok, ok: true} = finished[run_id]
    end

    assert [%{parallel: %{id: ^id, index: 2}, status: "spawn_error", text: text}] =
             for(%{type: :item_failed} = event <- events, do: event)

    assert text =~ "nobody"
  end

  test "a failing observer never affects the workflow" do
    scope = start_scope(profiles: %{"worker" => agent_spec("worker")})
    script = ~s|tackle.log("x") return tackle.await(tackle.spawn("worker", "go")).text|

    log =
      capture_log(fn ->
        assert {:ok, ref} =
                 Workflow.run(handle(scope), script, on_event: fn _event -> raise "boom" end)

        assert {:ok, ["go"]} = Workflow.await(ref, @workflow_timeout)
      end)

    assert log =~ "workflow progress callback failed: boom"
  end

  test "rejects an observer that is not a one-arity function" do
    scope = start_scope(profiles: %{})

    assert {:error, {:invalid_workflow_option, :on_event, :nope}} =
             Workflow.run(handle(scope), "return 1", on_event: :nope)
  end

  test "child events are forwarded as run events only when observed" do
    assert Progress.request_opts(nil, "scout") == []

    [event_callback: callback] = Progress.request_opts(observe(), "scout")
    {:ok, run_ref} = RunRef.new("scope", "run")
    child = Event.new(:message_delta, %{delta: "hi"})

    callback.(run_ref, child)

    assert_received {:progress,
                     %{type: :run_event, run_id: "run", profile: "scout", event: ^child}}
  end

  test "the run_workflow tool reports progress as workflow_progress events" do
    scope = start_scope(profiles: %{"scout" => agent_spec("scout")})
    test_pid = self()

    context = %{
      runtime: handle(scope),
      tool_call_id: "call-1",
      event_callback: fn event -> send(test_pid, {:event, event}) end
    }

    script = ~s|return tackle.await(tackle.spawn("scout", "map")).text|
    assert {:ok, "map"} = WorkflowTool.run(%{"script" => script}, context)

    assert_received {:event,
                     %Event{
                       type: :workflow_progress,
                       data: %{kind: :run_started, tool_call_id: "call-1", profile: "scout"}
                     }}

    assert_received {:event,
                     %Event{
                       type: :workflow_progress,
                       data: %{kind: :run_finished, tool_call_id: "call-1", ok: true}
                     }}
  end
end
