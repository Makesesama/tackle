defmodule Tackle.Runtime.LoopAgentTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Event
  alias Tackle.Lib.Message
  alias Tackle.Runtime
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.LoopAgent
  alias Tackle.Runtime.LoopAgent.Config
  alias Tackle.Runtime.Outcome
  alias Tackle.Runtime.ScopeSpec
  alias Tackle.Runtime.ScriptedLLM

  @moduletag :capture_log

  defmodule EchoTool do
    @behaviour Tackle.Lib.Tool

    def name, do: "echo"
    def description, do: "Reports its context to the test."
    def parameters_schema, do: []

    def execute(_args, context) do
      send(context.test_pid, {:tool_context, self(), context})
      {:ok, "echoed"}
    end
  end

  defmodule TurnHook do
    @behaviour Tackle.Lib.Hook

    def after_turn(state, _context) do
      send(state.context.test_pid, {:after_turn, state.status})
      :ok
    end
  end

  describe "configuration" do
    test "resolves models against its own providers and keeps the credential store" do
      store = {:store, make_ref()}

      assert {:ok, %Config{} = config} =
               Config.new(
                 providers: [ScriptedLLM],
                 model: "scripted/small",
                 thinking: "low",
                 credential_store: store,
                 llm_opts: [credential_store: :ignored, cache_key: "a"]
               )

      spec = AgentSpec.new!(name: "agent", config: config)
      assert LoopAgent.validate_spec(spec) == :ok
      assert {:error, _reason} = LoopAgent.validate_spec(%{spec | config: %{}})

      assert {:ok, configured} =
               LoopAgent.configure(spec,
                 model: "scripted/large",
                 thinking: "high",
                 max_steps: 4,
                 context: %{run: 1},
                 llm_opts: [credential_store: {:wrong, make_ref()}, cache_key: "b"]
               )

      assert LoopAgent.model_ref(configured) == "scripted/large"
      assert configured.config.context == %{run: 1}

      assert %{model: "scripted/large", thinking: "high", max_steps: 4, tools: []} =
               LoopAgent.describe(configured)

      assert {:ok, %{llm_opts: llm_opts}} = LoopAgent.llm(configured)
      assert llm_opts[:credential_store] == store
      assert llm_opts[:cache_key] == "b"
    end

    test "rejects what it cannot run" do
      assert {:error, {:missing_option, :model}} = Config.new(providers: [ScriptedLLM])
      assert {:error, _reason} = Config.new(providers: [ScriptedLLM], model: "other/model")

      assert {:error, :invalid_max_steps} =
               Config.new(providers: [ScriptedLLM], model: "scripted/small", max_steps: 0)

      assert {:error, :invalid_llm_opts} =
               Config.new(
                 providers: [ScriptedLLM],
                 model: "scripted/small",
                 llm_opts: %{},
                 thinking: "high"
               )

      assert {:error, :invalid_hooks} =
               Config.new(providers: [ScriptedLLM], model: "scripted/small", hooks: [String])

      spec = spec(&ScriptedLLM.block/2)
      assert {:error, :invalid_max_steps} = LoopAgent.configure(spec, max_steps: 0)
      assert {:error, _reason} = LoopAgent.select_model(spec, "unconfigured/model")
      assert {:error, _reason} = LoopAgent.configure(spec, thinking: "huge")
      assert {:error, _reason} = LoopAgent.configure(spec, context: nil)
      assert {:error, {:invalid_agent_option, :unknown}} = LoopAgent.configure(spec, unknown: 1)
    end
  end

  describe "turns" do
    test "runs a turn with tools, hooks, and the runtime reference, and keeps the conversation" do
      script = fn _schema, opts ->
        if Enum.any?(opts[:messages], &match?(%{role: :tool}, &1)),
          do: ScriptedLLM.answer(opts),
          else: ScriptedLLM.call_tool("echo", %{}, opts)
      end

      scope = scope(spec(script, tools: [EchoTool], hooks: [TurnHook]))
      root = scope.root_agent_ref

      assert {:ok, %{agent_state: %{messages: []}, active_turn: nil}} = Runtime.subscribe(root)
      assert {:ok, turn_id} = Runtime.submit(root, "Hi")
      assert is_binary(turn_id)

      assert_receive {:tool_context, tool_pid, context}, 2_000
      assert context.runtime == root
      {:ok, agent} = Runtime.session_pid(root)
      assert tool_pid != agent

      assert_receive {:tackle_runtime_event,
                      %Event{type: :turn_end, data: %{status: :completed}}},
                     2_000

      assert_receive {:after_turn, :completed}

      assert {:ok, %{agent_state: state, active_turn: nil}} = Runtime.session_snapshot(root)
      assert Tackle.Lib.last_answer(state) == "done"
      assert [%Message{role: :user, content: "Hi"} | _rest] = state.messages
    end

    test "continue runs without a new user message" do
      scope = scope(spec(fn _, opts -> ScriptedLLM.answer(opts, "again") end))
      root = scope.root_agent_ref
      {:ok, _snapshot} = Runtime.subscribe(root)

      assert {:ok, _turn} = Runtime.continue(root)
      assert_receive {:tackle_runtime_event, %Event{type: :turn_end}}, 2_000
      assert {:ok, %{agent_state: state}} = Runtime.session_snapshot(root)
      assert [%Message{role: :assistant, content: "again"}] = state.messages
    end

    test "allows one turn at a time and cancels it from the runtime and the scope" do
      scope = scope(spec(&ScriptedLLM.block/2))
      root = scope.root_agent_ref
      {:ok, _snapshot} = Runtime.subscribe(root)

      assert {:ok, turn_id} = Runtime.submit(root, "wait")
      assert_receive {:model_call, _pid, nil, opts}, 2_000
      assert {:ok, %{active_turn: ^turn_id}} = Runtime.session_snapshot(root)
      assert {:error, :turn_in_progress} = Runtime.submit(root, "again")
      assert {:error, :turn_in_progress} = Runtime.continue(root)
      assert {:error, :turn_in_progress} = Runtime.reconfigure(root, thinking: "high")

      assert :ok = Runtime.cancel_turn(root)

      assert_receive {:tackle_runtime_event,
                      %Event{type: :turn_end, data: %{status: :cancelled}}},
                     2_000

      assert :ok = eventually(fn -> idle?(root) end)
      # The signal was deleted once the turn settled.
      refute Cancellation.cancelled?(opts[:cancellation_signal])

      assert {:ok, _turn} = Runtime.submit(root, "wait again")
      assert_receive {:model_call, _pid, nil, _opts}, 2_000
      {:ok, pid} = Runtime.session_pid(root)
      send(pid, {:runtime_cancel, :scope_cancelled})

      assert_receive {:tackle_runtime_event,
                      %Event{type: :turn_end, data: %{status: :cancelled}}},
                     2_000
    end

    test "cancels a single tool call only during a turn" do
      scope = scope(spec(&ScriptedLLM.block/2))
      root = scope.root_agent_ref

      assert {:error, :no_active_turn} = Runtime.cancel_tool_call(root, "call-1", :stop)
      assert {:ok, _turn} = Runtime.submit(root, "wait")
      assert_receive {:model_call, _pid, nil, opts}, 2_000
      assert :ok = Runtime.cancel_tool_call(root, "call-1", :stop)

      assert Cancellation.cancelled?(Cancellation.for_call(opts[:cancellation_signal], "call-1"))
      refute Cancellation.cancelled?(opts[:cancellation_signal])
      :ok = Runtime.cancel_turn(root)
    end

    test "a crashed turn keeps the conversation and publishes turn_end with an error" do
      scope = scope(spec(&ScriptedLLM.block/2))
      root = scope.root_agent_ref
      {:ok, _snapshot} = Runtime.subscribe(root)

      assert {:ok, _turn} = Runtime.submit(root, "wait")
      assert_receive {:model_call, task, nil, _opts}, 2_000
      Process.exit(task, :kill)

      assert_receive {:tackle_runtime_event, %Event{type: :turn_end, data: %{status: :error}}},
                     2_000

      assert {:ok, %{agent_state: %{messages: []}, active_turn: nil}} =
               Runtime.session_snapshot(root)

      assert {:ok, pid} = Runtime.session_pid(root)
      assert Process.alive?(pid)
    end

    test "stopping the scope kills a turn that ignores cancellation" do
      stubborn = fn _, _ -> receive do: (:never -> :never) end
      scope = scope(spec(stubborn))
      assert {:ok, _turn} = Runtime.submit(scope.root_agent_ref, "wait")
      assert_receive {:model_call, task, nil, _opts}, 2_000
      monitor = Process.monitor(task)
      assert :ok = Runtime.stop_scope(scope.scope_ref)
      assert_receive {:DOWN, ^monitor, :process, ^task, _reason}, 3_000
    end
  end

  describe "subscribers and events" do
    test "drops subscribers that unsubscribe or exit and publishes only auxiliary events" do
      scope = scope(spec(&ScriptedLLM.block/2))
      root = scope.root_agent_ref
      {:ok, pid} = Runtime.session_pid(root)
      test = self()

      watcher =
        spawn(fn ->
          {:ok, _snapshot} = Runtime.subscribe(root)
          send(test, :subscribed)
          receive do: (:stop -> :ok)
        end)

      assert_receive :subscribed
      assert {:ok, _snapshot} = Runtime.subscribe(root)
      assert map_size(:sys.get_state(pid).subscribers) == 2

      send(watcher, :stop)
      assert :ok = eventually(fn -> map_size(:sys.get_state(pid).subscribers) == 1 end)

      narration = Event.new(:narration, %{text: "working", auxiliary: true})
      assert :ok = Runtime.publish_event(root, narration)
      assert_receive {:tackle_runtime_event, ^narration}

      assert {:error, {:invalid_event, _event}} =
               LoopAgent.call(pid, :publish_event, [Event.new(:narration, %{text: "x"})])

      assert :ok = Runtime.unsubscribe(root)
      assert :sys.get_state(pid).subscribers == %{}
    end

    test "rejects operations it does not support" do
      scope = scope(spec(&ScriptedLLM.block/2))
      {:ok, pid} = Runtime.session_pid(scope.root_agent_ref)

      assert {:error, {:unsupported_agent_operation, :deliver}} =
               LoopAgent.call(pid, :deliver, [:envelope])

      assert {:error, {:invalid_input, 1}} = LoopAgent.call(pid, :submit, [1])
    end
  end

  describe "delegation" do
    test "a child inherits the parent's current model and reports its outcome" do
      script = fn _, opts -> ScriptedLLM.answer(opts) end
      scope = scope(spec(script))

      assert {:ok, %{agent_state: state}} =
               Runtime.reconfigure(scope.root_agent_ref,
                 model: "scripted/large",
                 thinking: "medium"
               )

      assert state.llm.ref == "scripted/large"

      child = %{spec(script, name: "child") | model_source: :parent}
      assert {:ok, run} = Runtime.request_agent(scope.root_agent_ref, child, "Work")
      assert %Outcome{status: :ok} = outcome = Runtime.await(run, 5_000)
      assert Outcome.answer(outcome) == "done"
      assert outcome.agent_state.llm.ref == "scripted/large"
      assert outcome.agent_state.llm_opts[:reasoning_effort] == "medium"
      assert outcome.agent_state.context.runtime == run.agent_ref
    end

    test "provider errors settle as library errors and a killed turn as a runtime error" do
      scope = scope(spec(&ScriptedLLM.block/2))

      failing = spec(fn _, _ -> {:error, :provider_unavailable} end, name: "failing")
      assert {:ok, run} = Runtime.request_agent(scope.root_agent_ref, failing, "Work")
      assert %Outcome{status: :error, agent_state: %{error: error}} = Runtime.await(run, 5_000)
      assert error =~ "provider_unavailable"
      flush_model_calls()

      blocked = spec(&ScriptedLLM.block/2, name: "blocked")
      assert {:ok, run} = Runtime.request_agent(scope.root_agent_ref, blocked, "Work")
      assert_receive {:model_call, task, nil, _opts}, 2_000
      Process.exit(task, :kill)
      assert %Outcome{status: :runtime_error, reason: :killed} = Runtime.await(run, 5_000)
    end

    test "a step limit stops a tool-calling turn" do
      looping = fn _, opts -> ScriptedLLM.call_tool("missing_tool", %{}, opts) end
      scope = scope(spec(looping))
      child = spec(looping, name: "limited", max_steps: 1)
      assert {:ok, run} = Runtime.request_agent(scope.root_agent_ref, child, "Work")

      assert %Outcome{status: :error, agent_state: %{error: "Reached maximum iterations" <> _}} =
               Runtime.await(run, 5_000)
    end
  end

  defp spec(script, opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, "root")

    {:ok, config} =
      Config.new(
        Keyword.merge(
          [
            providers: [ScriptedLLM],
            model: "scripted/small",
            system_prompt: "Help.",
            context: %{test_pid: self()},
            llm_opts: [script: script, test_pid: self()]
          ],
          opts
        )
      )

    AgentSpec.new!(name: name, config: config, timeout: 5_000, allow_delegation: true)
  end

  defp scope(root) do
    {:ok, scope} = Runtime.start_scope(ScopeSpec.new!(backend: LoopAgent, root_spec: root))
    on_exit(fn -> stop_scope(scope.scope_ref) end)
    scope
  end

  defp stop_scope(ref) do
    Runtime.stop_scope(ref)
  catch
    :exit, _reason -> :ok
  end

  defp flush_model_calls do
    receive do
      {:model_call, _pid, _schema, _opts} -> flush_model_calls()
    after
      0 -> :ok
    end
  end

  defp idle?(ref), do: match?({:ok, %{active_turn: nil}}, Runtime.session_snapshot(ref))

  defp eventually(fun, attempts \\ 200)
  defp eventually(_fun, 0), do: :timeout

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
