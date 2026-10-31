defmodule Tackle.Hub.AgentConfigTest do
  use ExUnit.Case, async: true

  alias Tackle.Hub.{AgentConfig, CredentialStore, ReviewAdapter}
  alias Tackle.Lib.Cancellation
  alias Tackle.Review
  alias Tackle.Review.{Change, Diff, Finding}
  alias Tackle.Review.Tools.{ReportFindings, ReportVerdict}
  alias Tackle.Runtime
  alias Tackle.Runtime.{AgentSpec, LoopAgent, ScopeSpec}

  @moduletag :capture_log

  @owner_id "00000000-0000-4000-8000-000000000001"

  test "review agents keep the owner's credential store through reconfiguration" do
    spec = spec("agent", fn _, opts -> ReviewAdapter.answer(opts) end, context: %{cwd: "/repo"})

    assert LoopAgent.validate_spec(spec) == :ok
    assert {:error, _reason} = LoopAgent.validate_spec(%{spec | config: %{}})

    assert {:ok, configured} =
             LoopAgent.configure(spec,
               model: "scripted/verifier",
               thinking: "high",
               max_steps: 4,
               context: %{review: :run},
               llm_opts: [prompt_cache_key: "review", credential_store: {:wrong, make_ref()}]
             )

    assert LoopAgent.model_ref(configured) == "scripted/verifier"
    assert configured.config.context == %{cwd: "/repo", review: :run}

    assert %{model: "scripted/verifier", thinking: "high", max_steps: 4} =
             LoopAgent.describe(configured)

    assert {:ok, client} = LoopAgent.llm(configured)
    assert client.llm_opts[:credential_store] == CredentialStore.handle(@owner_id)
    assert client.llm_opts[:prompt_cache_key] == "review"
    assert client.llm_opts[:test_pid] == self()
    assert {:error, _reason} = LoopAgent.select_model(spec, "unconfigured/model")
    assert {:error, _reason} = LoopAgent.configure(spec, thinking: "huge")
    assert {:error, :invalid_max_steps} = LoopAgent.configure(spec, max_steps: 0)
    assert {:error, _reason} = LoopAgent.configure(spec, context: nil)
    assert {:error, _reason} = LoopAgent.configure(spec, unknown: true)
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

  test "cancelling a review tears down its delegated runs" do
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
      AgentConfig.new(
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

  defp scope(root, profiles) do
    {:ok, scope} =
      Runtime.start_scope(ScopeSpec.new!(backend: LoopAgent, root_spec: root, profiles: profiles))

    on_exit(fn -> stop_scope(scope.scope_ref) end)
    scope
  end

  defp stop_scope(ref) do
    Runtime.stop_scope(ref)
  catch
    :exit, _reason -> :ok
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
