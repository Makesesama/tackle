defmodule Tackle.Web.AgentBackendTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.{Cancellation, Event}
  alias Tackle.Review
  alias Tackle.Review.{Change, Diff, Finding}
  alias Tackle.Review.Tools.{ReportFindings, ReportVerdict}
  alias Tackle.Runtime
  alias Tackle.Runtime.{AgentSpec, Outcome, ScopeSpec}
  alias Tackle.Web.{AgentBackend, CredentialStore, ReviewAdapter}

  @moduletag :capture_log

  @owner_id "00000000-0000-4000-8000-000000000001"

  test "spec callbacks select models, merge context/options, validate limits and keep the stable store" do
    spec = spec("agent", fn _, opts -> ReviewAdapter.answer(opts) end, context: %{cwd: "/repo"})

    assert AgentBackend.validate_spec(spec) == :ok
    assert {:error, _reason} = AgentBackend.validate_spec(%{spec | config: %{}})

    assert {:ok, configured} =
             AgentBackend.configure(spec,
               model: "scripted/verifier",
               thinking: "high",
               max_steps: 4,
               context: %{review: :run},
               llm_opts: [prompt_cache_key: "review", credential_store: {:wrong, make_ref()}]
             )

    assert AgentBackend.model_ref(configured) == "scripted/verifier"
    assert configured.config.context == %{cwd: "/repo", review: :run}

    assert %{model: "scripted/verifier", thinking: "high", max_steps: 4} =
             AgentBackend.describe(configured)

    assert {:ok, client} = AgentBackend.llm(configured)
    assert client.llm_opts[:credential_store] == CredentialStore.handle(@owner_id)
    assert client.llm_opts[:prompt_cache_key] == "review"
    assert client.llm_opts[:test_pid] == self()
    assert {:error, _reason} = AgentBackend.select_model(spec, "unconfigured/model")
    assert {:error, _reason} = AgentBackend.configure(spec, thinking: "huge")
    assert {:error, :invalid_max_steps} = AgentBackend.configure(spec, max_steps: 0)
    assert {:error, _reason} = AgentBackend.configure(spec, context: nil)
    assert {:error, _reason} = AgentBackend.configure(spec, unknown: true)
  end

  test "a whole review detects, verifies, scores and forwards events without a harness or live provider" do
    profiles = %{
      "review-detector" => spec("review-detector", &review_script/2, tools: [ReportFindings]),
      "review-verifier" => spec("review-verifier", &review_script/2, tools: [ReportVerdict])
    }

    scope = scope(spec("root", &review_script/2), profiles)
    parent = self()

    assert {:ok, result} =
             Review.run(change(),
               requester: scope.root_agent_ref,
               profiles: profiles,
               rules: [],
               models: [
                 detector: "scripted/detector",
                 verifier: "scripted/verifier",
                 scorer: "scripted/scorer"
               ],
               thinking: [detector: "low", verifier: "high"],
               max_steps: [detector: 3, verifier: 2],
               on_event: &send(parent, {:review_event, &1})
             )

    assert [%Finding{title: "Check the key", verdict: :confirmed, confidence: 0.95}] =
             result.blocking

    assert result.summary.verdict == :blocking
    assert result.summary.detected == 1
    assert result.summary.failed_units == []
    assert result.summary.verification_failures == []
    assert result.summary.scoring_failures == []
    assert result.usage.input_tokens > 0
    assert result.summary.stages.detector.runs == 2
    assert result.summary.stages.verifier.runs == 1
    assert result.summary.stages.scorer.runs == 1
    assert_received {:review_event, {:done, ^result}}

    calls = calls()

    assert Enum.all?(calls, fn {_schema, opts} ->
             opts[:credential_store] == CredentialStore.handle(@owner_id)
           end)

    assert Enum.any?(calls, fn {schema, opts} -> schema != nil and opts[:model] == "scorer" end)

    assert Enum.any?(calls, fn {_, opts} ->
             opts[:model] == "verifier" and opts[:reasoning_effort] == "high"
           end)
  end

  test "delegation inherits the parent's current model/thinking and reports the terminal outcome" do
    script = fn _, opts -> ReviewAdapter.answer(opts) end
    scope = scope(spec("root", script))

    assert {:ok, _snapshot} =
             Runtime.reconfigure(scope.root_agent_ref,
               model: "scripted/verifier",
               thinking: "medium"
             )

    child = %{spec("child", script) | model_source: :parent}
    assert {:ok, run} = Runtime.request_agent(scope.root_agent_ref, child, "Review")
    assert %Outcome{status: :ok} = result = Runtime.await(run, 5_000)
    assert Outcome.answer(result) == "done"
    assert result.agent_state.llm.ref == "scripted/verifier"
    assert result.agent_state.llm_opts[:reasoning_effort] == "medium"
    assert result.agent_state.context.runtime == run.agent_ref
    assert AgentBackend.outcome(result, run.agent_ref) == result
  end

  test "one active turn, streaming subscriptions and cooperative cancellation on both entry points" do
    scope = scope(spec("root", &ReviewAdapter.block/2))
    root = scope.root_agent_ref
    assert {:ok, _snapshot} = Runtime.subscribe(root)
    assert {:ok, _snapshot} = Runtime.subscribe(root)
    assert {:ok, _turn} = Runtime.submit(root, "wait")
    assert_receive {:model_call, _pid, nil, opts}, 2_000
    assert_receive {:tackle_runtime_event, %Event{type: :message_delta}}, 2_000
    assert {:error, :busy} = Runtime.submit(root, "again")
    assert {:error, :busy} = Runtime.reconfigure(root, thinking: "high")
    assert :ok = Runtime.cancel_turn(root)
    assert_receive {:tackle_runtime_event, %Event{type: :turn_cancelled}}, 2_000
    assert :ok = eventually(fn -> settled?(root, :cancelled) end)
    refute Cancellation.cancelled?(opts[:cancellation_signal])

    assert {:ok, _turn} = Runtime.submit(root, "wait again")
    assert_receive {:model_call, _pid, nil, _opts}, 2_000
    {:ok, pid} = Runtime.session_pid(root)
    send(pid, {:runtime_cancel, :test_cancel})
    assert :ok = eventually(fn -> settled?(root, :cancelled) end)
    assert :ok = Runtime.unsubscribe(root)
    assert :ok = Runtime.unsubscribe(root)
    assert :sys.get_state(pid).subscribers == %{}
  end

  test "provider errors settle as library errors; a killed turn reports a runtime error" do
    scope = scope(spec("root", &ReviewAdapter.block/2))
    failed = spec("failed", fn _, _ -> {:error, :provider_unavailable} end)
    assert {:ok, run} = Runtime.request_agent(scope.root_agent_ref, failed, "Review")
    assert %Outcome{status: :error, agent_state: %{error: error}} = Runtime.await(run, 5_000)
    assert error =~ "provider_unavailable"
    _ = calls()

    blocked = spec("blocked", &ReviewAdapter.block/2)
    assert {:ok, run} = Runtime.request_agent(scope.root_agent_ref, blocked, "Review")
    assert_receive {:model_call, pid, nil, _opts}, 2_000
    Process.exit(pid, :kill)
    assert %Outcome{status: :runtime_error, reason: :killed} = Runtime.await(run, 5_000)
  end

  test "stopping the scope kills a turn which ignores cancellation" do
    stubborn = fn _, _ -> receive do: (:never -> :never) end
    scope = scope(spec("root", stubborn))
    assert {:ok, _turn} = Runtime.submit(scope.root_agent_ref, "wait")
    assert_receive {:model_call, pid, nil, _opts}, 2_000
    monitor = Process.monitor(pid)
    assert :ok = Runtime.stop_scope(scope.scope_ref)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 2_000
  end

  test "step limits stop a tool-calling turn, and cancelling a review tears down delegated runs" do
    looping = fn _, opts -> ReviewAdapter.report("missing_tool", %{}, opts) end
    scope = scope(spec("root", looping))
    child = spec("limited", looping, max_steps: 1)
    {:ok, run} = Runtime.request_agent(scope.root_agent_ref, child, "Review")

    assert %Outcome{status: :error, agent_state: %{error: "Reached maximum iterations" <> _}} =
             Runtime.await(run, 5_000)

    _ = calls()

    profiles = %{
      "review-detector" =>
        spec("review-detector", &ReviewAdapter.block/2, tools: [ReportFindings]),
      "review-verifier" => spec("review-verifier", &ReviewAdapter.block/2, tools: [ReportVerdict])
    }

    scope = scope(spec("root", &ReviewAdapter.block/2), profiles)
    signal = Cancellation.new_signal()

    task =
      Task.async(fn ->
        Review.run(change(),
          requester: scope.root_agent_ref,
          profiles: profiles,
          rules: [],
          cancellation: signal
        )
      end)

    assert_receive {:model_call, _pid, nil, _opts}, 2_000
    Cancellation.cancel(signal)
    assert Task.await(task, 5_000) == {:error, :cancelled}

    assert :ok =
             eventually(fn ->
               match?({:ok, %{agent_count: 1}}, Runtime.scope_snapshot(scope.scope_ref))
             end)

    Cancellation.delete(signal)
  end

  defp spec(name, script, opts \\ []) do
    {:ok, config} =
      AgentBackend.config(
        Keyword.merge(
          [
            providers: [ReviewAdapter],
            owner_id: @owner_id,
            model: "scripted/detector",
            system_prompt: "Review.",
            max_steps: 6,
            llm_opts: [script: script, test_pid: self()]
          ],
          opts
        )
      )

    AgentSpec.new!(name: name, config: config, timeout: 5_000, allow_delegation: true)
  end

  defp scope(root, profiles \\ %{}) do
    {:ok, scope} =
      Runtime.start_scope(
        ScopeSpec.new!(backend: AgentBackend, root_spec: root, profiles: profiles)
      )

    on_exit(fn -> stop_scope(scope.scope_ref) end)
    scope
  end

  defp stop_scope(ref) do
    Runtime.stop_scope(ref)
  catch
    :exit, _reason -> :ok
  end

  defp settled?(ref, status) do
    {:ok, pid} = Runtime.session_pid(ref)
    state = :sys.get_state(pid)
    state.task == nil and state.agent_state.status == status
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(_fun, 0), do: :timeout

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end

  defp calls do
    receive do
      {:model_call, _pid, schema, opts} -> [{schema, opts} | calls()]
    after
      0 -> []
    end
  end

  defp review_script(schema, opts) when not is_nil(schema) do
    scores =
      for [id] <-
            Regex.scan(~r/<comment id="(C\d+)"/, ReviewAdapter.prompt(opts),
              capture: :all_but_first
            ),
          do: %{"id" => id, "confidence" => 0.95}

    ReviewAdapter.response(%{"scores" => scores}, opts)
  end

  defp review_script(nil, opts) do
    prompt = ReviewAdapter.prompt(opts)

    cond do
      Enum.any?(opts[:messages], &(&1.role == :tool)) ->
        ReviewAdapter.block(nil, opts)

      String.starts_with?(prompt, "Verify") ->
        ReviewAdapter.report(
          "report_verdict",
          %{
            "finding" => "F1",
            "verdict" => "confirmed",
            "evidence" => "lib/a.ex:2 reads map.key without a guard."
          },
          opts
        )

      String.contains?(prompt, ~s(<unit id="lib/a.ex#1">)) ->
        ReviewAdapter.report("report_findings", %{"findings" => [finding()]}, opts)

      true ->
        ReviewAdapter.report("report_findings", %{"findings" => []}, opts)
    end
  end

  defp finding do
    %{
      "title" => "Check the key",
      "category" => "correctness",
      "severity" => "high",
      "blocking" => true,
      "confidence" => 0.8,
      "rule_id" => nil,
      "location" => %{"path" => "lib/a.ex", "side" => "new", "start_line" => 2, "end_line" => 2},
      "trigger" => "A map without :key reaches g/1",
      "body" => "map.key raises KeyError.",
      "suggestion" => nil
    }
  end

  defp change do
    {:ok, diff} =
      Diff.parse("""
      diff --git a/lib/a.ex b/lib/a.ex
      --- a/lib/a.ex
      +++ b/lib/a.ex
      @@ -1,2 +1,3 @@
       defmodule A do
      +  def g(map), do: map.key
       end
      """)

    %Change{
      cwd: "/repo",
      root: "/repo",
      mode: :range,
      base_ref: "main",
      base_sha: String.duplicate("a", 40),
      head_sha: String.duplicate("b", 40),
      diff: diff
    }
  end
end
