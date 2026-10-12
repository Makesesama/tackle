defmodule Tackle.ReviewTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import Tackle.Test.Runtime, only: [start_scope: 1, handle: 1, eventually: 1]

  alias Tackle.Config
  alias Tackle.Lib.Cancellation
  alias Tackle.Review
  alias Tackle.Review.{Change, Diff, Finding, History, Result, Rules}
  alias Tackle.Runtime.{AgentSpec, ScopeSpec}
  alias Tackle.Tools.{ReportFindings, ReportVerdict}

  defmodule Adapter do
    @moduledoc false
    # Scripted provider for review runs. The script decides each response from
    # the stage (detector, verifier, or scorer) and the request so far.

    @behaviour Tackle.Lib.LLM

    alias Tackle.Lib.Cancellation

    @impl true
    def adapter_id, do: "review"

    @impl true
    def models, do: ["fake", "other"]

    @impl true
    def model_info(_model), do: %{context_window: 100_000, max_output_tokens: 1_000}

    @impl true
    def generate(schema, opts) do
      messages = Keyword.get(opts, :messages, [])

      prompt =
        Enum.find_value(messages, "", fn
          %{role: :user, content: content} -> content
          _other -> nil
        end)

      request = %{
        prompt: prompt,
        tool_results: for(%{role: :tool, content: content} <- messages, do: content),
        model: Keyword.fetch!(opts, :model)
      }

      stage =
        cond do
          schema != nil -> :scorer
          String.starts_with?(prompt, "Verify") -> :verifier
          true -> :detector
        end

      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:llm_call, stage, request})

      opts
      |> Keyword.fetch!(:script)
      |> then(& &1.(stage, request))
      |> reply(opts, test_pid)
    end

    defp reply({:findings, findings}, opts, _test_pid),
      do: tool_call("report_findings", %{"findings" => findings}, opts)

    defp reply({:verdict, verdict, evidence}, opts, _test_pid),
      do: tool_call("report_verdict", %{"verdict" => verdict, "evidence" => evidence}, opts)

    defp reply({:answer, text}, opts, _test_pid),
      do: response(%{"content" => text, "tool_calls" => []}, opts)

    defp reply({:confidence, value}, opts, _test_pid),
      do: response(%{"confidence" => value}, opts)

    defp reply({:error, reason}, _opts, _test_pid), do: {:error, reason}

    defp reply(:block, opts, test_pid) do
      if Cancellation.cancelled?(Keyword.get(opts, :cancellation_signal)) do
        {:error, :cancelled}
      else
        Process.sleep(10)
        reply(:block, opts, test_pid)
      end
    end

    defp tool_call(name, arguments, opts) do
      call = %{
        "id" => "call-#{System.unique_integer([:positive])}",
        "name" => name,
        "arguments" => arguments
      }

      response(%{"content" => nil, "tool_calls" => [call]}, opts)
    end

    defp response(data, opts) do
      {:ok,
       %{
         data: data,
         usage: %{input_tokens: 10, output_tokens: 5},
         model: Keyword.fetch!(opts, :model)
       }}
    end
  end

  @diff """
  diff --git a/lib/a.ex b/lib/a.ex
  --- a/lib/a.ex
  +++ b/lib/a.ex
  @@ -1,3 +1,4 @@
   defmodule A do
  -  def f(x), do: x
  +  def f(x), do: x + 1
  +  def g(map), do: map.key
   end
  diff --git a/lib/b.ex b/lib/b.ex
  --- a/lib/b.ex
  +++ b/lib/b.ex
  @@ -1,2 +1,3 @@
   defmodule B do
  +  def h, do: :ok
   end
  """

  @rule """
  ---
  id: missing-nil-check
  category: correctness
  severity: high
  ---
  Values that can be absent are checked before use.
  """

  defp change(diff_text \\ @diff) do
    {:ok, diff} = Diff.parse(diff_text)

    %Change{
      cwd: "/repo",
      root: "/repo",
      mode: :range,
      base_ref: "main",
      base_sha: String.duplicate("a", 40),
      head_sha: String.duplicate("b", 40),
      diff: diff,
      context_diff: diff
    }
  end

  defp rules do
    {:ok, rule} = Rules.parse(@rule, "missing-nil-check.md", :project)
    [rule]
  end

  defp finding(overrides) do
    Map.merge(
      %{
        "title" => "Guard against a missing key",
        "category" => "correctness",
        "severity" => "high",
        "blocking" => true,
        "confidence" => 0.7,
        "rule_id" => "missing-nil-check",
        "location" => location(3, 3),
        "trigger" => "g/1 is called with a map without :key",
        "body" => "map.key raises KeyError for such maps.",
        "suggestion" => nil
      },
      overrides
    )
  end

  defp location(first, last),
    do: %{"path" => "lib/a.ex", "side" => "new", "start_line" => first, "end_line" => last}

  defp nil_check, do: finding(%{})

  defp rename do
    finding(%{
      "title" => "Rename f to increment",
      "category" => "readability",
      "severity" => "low",
      "blocking" => false,
      "confidence" => 0.6,
      "rule_id" => nil,
      "location" => location(2, 2),
      "trigger" => "Always",
      "body" => "The name f says nothing."
    })
  end

  defp unit?(request, id), do: String.contains?(request.prompt, ~s(<unit id="#{id}">))

  # A detector that reports `findings` for lib/a.ex and nothing elsewhere, a
  # verifier that confirms the nil check and rejects the rest, and a scorer
  # that answers 0.9.
  defp script(overrides \\ %{}) do
    findings = Map.get(overrides, :findings, [nil_check(), rename()])

    defaults = %{
      detector: fn
        %{tool_results: []} = request ->
          if unit?(request, "lib/a.ex#1"), do: {:findings, findings}, else: {:findings, []}

        _request ->
          {:answer, "done"}
      end,
      verifier: fn
        %{tool_results: []} = request ->
          if request.prompt =~ "Guard against",
            do: {:verdict, "confirmed", "lib/a.ex:3 reads map.key unguarded."},
            else: {:verdict, "rejected", "Naming is not a defect."}

        _request ->
          {:answer, "ok"}
      end,
      scorer: fn _request -> {:confidence, 0.9} end
    }

    handlers = Map.merge(defaults, overrides)
    fn stage, request -> Map.fetch!(handlers, stage).(request) end
  end

  defp stage_spec(name, tool, script, opts \\ []) do
    {:ok, config} =
      Config.new(
        adapters: [Adapter],
        model: "review/fake",
        tools: [tool],
        system_prompt: "Review stage.",
        max_iterations: Keyword.get(opts, :max_iterations, 6),
        llm_opts: [test_pid: self(), script: script]
      )

    AgentSpec.new!(
      name: name,
      config: config,
      timeout: 5_000,
      model_source: Keyword.get(opts, :model_source, :configured)
    )
  end

  defp profiles(script, opts \\ []) do
    %{
      "review-detector" =>
        stage_spec("review-detector", ReportFindings, script, Keyword.get(opts, :detector, [])),
      "review-verifier" =>
        stage_spec("review-verifier", ReportVerdict, script, Keyword.get(opts, :verifier, []))
    }
  end

  defp review(change, script, opts \\ []) do
    {profile_opts, opts} = Keyword.pop(opts, :profile_opts, [])
    profiles = profiles(script, profile_opts)
    scope = start_scope(root: [allow_delegation: true], profiles: profiles)
    test_pid = self()

    opts =
      Keyword.merge(
        [
          requester: handle(scope),
          profiles: profiles,
          rules: rules(),
          on_event: &send(test_pid, {:review_event, &1})
        ],
        opts
      )

    Review.run(change, opts)
  end

  defp events do
    receive do
      {:review_event, event} -> [event | events()]
    after
      0 -> []
    end
  end

  defp calls(stage) do
    receive do
      {:llm_call, ^stage, request} -> [request | calls(stage)]
    after
      0 -> []
    end
  end

  defp index_of(events, fun), do: Enum.find_index(events, fun)

  test "reviews a change: detects, verifies, scores, and ranks findings" do
    assert {:ok, %Result{} = result} = review(change(), script())

    assert [%Finding{} = shown] = result.blocking
    assert shown.title == "Guard against a missing key"
    assert shown.rule_id == "missing-nil-check"
    assert shown.verdict == :confirmed
    assert shown.confidence == 0.9
    assert shown.support == 1
    assert shown.location == %{path: "lib/a.ex", side: :new, start_line: 3, end_line: 3}
    assert is_binary(shown.fingerprint) and byte_size(shown.fingerprint) == 32
    assert result.optional == []

    assert [%{finding: %Finding{title: "Rename f to increment"}, evidence: "Naming" <> _}] =
             result.rejected

    assert %{
             verdict: :blocking,
             profile: :default,
             samples: 1,
             units: 3,
             files: ["lib/a.ex", "lib/b.ex"],
             failed_units: [],
             detected: 2,
             candidates: 2,
             confirmed: 1,
             uncertain: 0,
             rejected: 1,
             blocking: 1,
             optional: 0,
             verification_failures: [],
             scoring_failures: []
           } = result.summary

    # 3 units × 2 detector calls, 2 candidates × 2 verifier calls, 1 scorer call.
    assert result.usage.input_tokens == 110
    assert result.usage.output_tokens == 55

    detector_calls = Enum.filter(calls(:detector), &(&1.tool_results == []))
    [detector_call] = Enum.filter(detector_calls, &unit?(&1, "lib/a.ex#1"))

    assert detector_call.prompt =~ ~s(<rule id="missing-nil-check")
    assert detector_call.prompt =~ "[+ 3]   def g(map), do: map.key"

    assert detector_call.prompt =~
             "Changed lines your findings may point at:\nlib/a.ex: new 2-3; old 2\n"

    [change_call] = Enum.filter(detector_calls, &unit?(&1, "change"))
    assert change_call.prompt =~ "Review the change as a whole"
    assert change_call.prompt =~ "lib/a.ex: new 2-3; old 2\nlib/b.ex: new 2"

    verifier_calls = Enum.filter(calls(:verifier), &(&1.tool_results == []))
    nil_check_call = Enum.find(verifier_calls, &(&1.prompt =~ "Guard against"))
    assert nil_check_call.prompt =~ "It cites this rule:\n<rule id=\"missing-nil-check\">"
    assert nil_check_call.prompt =~ "Location: lib/a.ex:3-3 (new side)"

    events = events()
    assert hd(events) == {:started, %{units: 3}}
    assert List.last(events) == {:done, result}

    for id <- ["change", "lib/a.ex#1", "lib/b.ex#1"] do
      started = index_of(events, &(&1 == {:unit, id, :started}))
      done = index_of(events, &(&1 == {:unit, id, :done}))
      assert started < done
    end

    candidates = for {:candidate, finding} <- events, do: finding.title
    assert Enum.sort(candidates) == ["Guard against a missing key", "Rename f to increment"]

    last_candidate = events |> Enum.with_index() |> Enum.filter(&match?({{:candidate, _}, _}, &1))
    first_verdict = index_of(events, &match?({:verdict, _, _}, &1))
    assert elem(List.last(last_candidate), 1) < first_verdict

    assert {:verdict, shown.fingerprint, :confirmed} in events
    [rejected] = result.rejected
    assert {:verdict, rejected.finding.fingerprint, :rejected} in events
  end

  test "an invalid location is returned to the model, and the corrected finding counts" do
    script =
      script(%{
        detector: fn
          %{tool_results: []} = request ->
            if unit?(request, "lib/a.ex#1"),
              do: {:findings, [finding(%{"location" => location(10, 10)})]},
              else: {:findings, []}

          %{tool_results: [error]} = request ->
            if unit?(request, "lib/a.ex#1") and error =~ "contain no changed line",
              do: {:findings, [nil_check()]},
              else: {:answer, "done"}

          _request ->
            {:answer, "done"}
        end
      })

    assert {:ok, result} = review(change(), script)
    assert [%Finding{location: %{start_line: 3}}] = result.blocking
    assert result.summary.detected == 1

    retry =
      Enum.find(calls(:detector), &(unit?(&1, "lib/a.ex#1") and match?([_], &1.tool_results)))

    assert [error] = retry.tool_results
    assert error =~ "No findings were recorded"
    assert error =~ "findings[1].location: new line 10 of lib/a.ex contain no changed line"
    assert error =~ "changed new lines: 2-3"
  end

  test "a failing unit is reported while the others are still reviewed" do
    script =
      script(%{
        detector: fn
          %{tool_results: []} = request ->
            cond do
              unit?(request, "lib/b.ex#1") -> {:error, :provider_down}
              unit?(request, "lib/a.ex#1") -> {:findings, [nil_check()]}
              true -> {:findings, []}
            end

          _request ->
            {:answer, "done"}
        end
      })

    assert {:ok, result} = review(change(), script)
    assert [%Finding{title: "Guard against a missing key"}] = result.blocking
    assert [%{unit: "lib/b.ex#1", reason: {:agent_error, _message}}] = result.summary.failed_units

    events = events()
    assert Enum.any?(events, &match?({:unit, "lib/b.ex#1", {:failed, {:agent_error, _}}}, &1))
    assert {:unit, "lib/a.ex#1", :done} in events
  end

  describe "a run that ends with an error after reporting" do
    test "keeps the detector's findings when the call after the report fails" do
      script =
        script(%{
          findings: [nil_check()],
          detector: fn
            %{tool_results: []} = request ->
              if unit?(request, "lib/a.ex#1"),
                do: {:findings, [nil_check()]},
                else: {:findings, []}

            _request ->
              {:error, :provider_down}
          end
        })

      assert {:ok, result} = review(change(), script)

      assert [%Finding{title: "Guard against a missing key", verdict: :confirmed}] =
               result.blocking

      assert %{failed_units: [], detected: 1} = result.summary

      events = events()
      for id <- ["change", "lib/a.ex#1", "lib/b.ex#1"], do: assert({:unit, id, :done} in events)
    end

    test "keeps the detector's findings when the report used the last step" do
      script =
        script(%{
          detector: fn request ->
            cond do
              unit?(request, "lib/a.ex#1") -> {:findings, [nil_check()]}
              # Every finding is invalid, so nothing is recorded.
              unit?(request, "lib/b.ex#1") -> {:findings, [nil_check()]}
              true -> {:answer, "Nothing to report."}
            end
          end
        })

      assert {:ok, result} =
               review(change(), script, profile_opts: [detector: [max_iterations: 1]])

      assert [%Finding{title: "Guard against a missing key"}] = result.blocking
      assert result.summary.detected == 1

      # A run that recorded no report before the step limit still fails.
      assert [%{unit: "lib/b.ex#1", reason: {:agent_error, "Reached maximum iterations" <> _}}] =
               result.summary.failed_units

      # Each detector run made exactly one model call.
      assert [_, _, _] = calls(:detector)
    end

    test "keeps a rejected verdict, so the finding stays dropped" do
      script =
        script(%{
          findings: [nil_check()],
          verifier: fn
            %{tool_results: []} -> {:verdict, "rejected", "lib/a.ex:3 is only reached with :key."}
            _request -> {:error, :provider_down}
          end
        })

      assert {:ok, result} = review(change(), script)
      assert result.blocking == [] and result.optional == []
      assert [%{finding: %Finding{} = rejected, evidence: "lib/a.ex:3" <> _}] = result.rejected
      assert %{rejected: 1, uncertain: 0, verification_failures: []} = result.summary
      assert {:verdict, rejected.fingerprint, :rejected} in events()
      assert calls(:scorer) == []
    end
  end

  test "fails when every unit fails" do
    script = script(%{detector: fn _request -> {:error, :provider_down} end})

    assert {:error, {:detection_failed, failures}} = review(change(), script)
    assert Enum.map(failures, & &1.unit) |> Enum.sort() == ["change", "lib/a.ex#1", "lib/b.ex#1"]
    assert {:error, {:detection_failed, _}} = List.last(events())
  end

  test "the cancellation signal stops the review and its runs" do
    signal = Cancellation.new_signal()
    profiles = profiles(script(%{detector: fn _request -> :block end}))
    scope = start_scope(root: [allow_delegation: true], profiles: profiles)
    parent = self()

    task =
      Task.async(fn ->
        Review.run(change(),
          requester: handle(scope),
          profiles: profiles,
          rules: [],
          cancellation: signal,
          on_event: &send(parent, {:review_event, &1})
        )
      end)

    assert_receive {:llm_call, :detector, _request}, 2_000
    Cancellation.cancel(signal)

    assert Task.await(task, 5_000) == {:error, :cancelled}
    assert {:error, :cancelled} = List.last(events())

    # The detector runs are gone; only the root agent is left in the scope.
    assert :ok =
             eventually(fn ->
               match?({:ok, %{agent_count: 1}}, Tackle.Runtime.scope_snapshot(scope.scope_ref))
             end)
  end

  test "cancelling the requester's branch cancels the review" do
    profiles = profiles(script(%{detector: fn _request -> :block end}))
    scope = start_scope(root: [allow_delegation: true], profiles: profiles)
    parent = self()

    task =
      Task.async(fn ->
        Review.run(change(),
          requester: handle(scope),
          profiles: profiles,
          rules: [],
          on_event: &send(parent, {:review_event, &1})
        )
      end)

    assert_receive {:llm_call, :detector, _request}, 2_000
    :ok = Tackle.Runtime.cancel(scope.root_agent_ref)

    assert Task.await(task, 5_000) == {:error, :cancelled}
    assert {:error, :cancelled} = List.last(events())
  end

  test "an empty change, or one with only skipped files, makes no model calls" do
    assert {:ok, result} = review(change(""), script())
    assert result.blocking == [] and result.optional == []
    assert %{units: 0, verdict: :clean, detected: 0, candidates: 0} = result.summary
    assert events() == [{:started, %{units: 0}}, {:done, result}]

    lock_only = """
    diff --git a/mix.lock b/mix.lock
    --- a/mix.lock
    +++ b/mix.lock
    @@ -1 +1 @@
    -old
    +new
    """

    assert {:ok, result} = review(change(lock_only), script())
    assert result.summary.units == 0
    assert [%{path: "mix.lock", reason: :lock_file}] = result.summary.skipped
    refute_received {:llm_call, _stage, _request}
  end

  test "a verifier without a verdict keeps the finding as uncertain" do
    script =
      script(%{findings: [nil_check()], verifier: fn _request -> {:answer, "Looks fine."} end})

    assert {:ok, result} = review(change(), script)
    assert [%Finding{verdict: :uncertain}] = result.blocking
    assert %{uncertain: 1, verification_failures: [%{reason: :no_verdict}]} = result.summary

    assert {:verdict, _fingerprint, :uncertain} =
             Enum.find(events(), &match?({:verdict, _, _}, &1))

    assert {:ok, quiet} = review(change(), script, profile: :quiet)
    assert quiet.blocking == []
    assert [%{reason: :uncertain}] = quiet.dropped
  end

  test "known fingerprints are not reported again" do
    script = script(%{findings: [nil_check()]})
    assert {:ok, first} = review(change(), script)
    [%Finding{fingerprint: fingerprint}] = first.blocking
    _ = calls(:verifier)

    assert {:ok, second} = review(change(), script, known_fingerprints: [fingerprint])
    assert second.blocking == []
    assert [%{reason: :known, finding: %Finding{fingerprint: ^fingerprint}}] = second.dropped
    assert second.summary.candidates == 0
    assert calls(:verifier) == []
  end

  describe "history" do
    setup do
      {:ok, history} = History.open("/repo", home: Tackle.Test.Runtime.tmp_home())
      {:ok, history: history}
    end

    test "records the run with its shown and rejected findings", %{history: history} do
      assert {:ok, result} = review(change(), script(), history: history)
      [shown] = result.blocking
      [%{finding: rejected}] = result.rejected
      assert result.summary.warnings == []

      assert {:ok, [run]} = History.runs(history)
      assert %{"blocking" => 1, "rejected" => 1, "candidates" => 2} = run["summary"]
      assert [%{"id" => "missing-nil-check", "status" => "active"}] = run["rules"]
      assert Map.keys(run["prompts"]) == ["review-detector", "review-verifier"]
      assert run["usage"]["input_tokens"] == 110

      assert {:ok, events} = History.finding_events(history)

      assert Enum.map(events, &{&1["event"], &1["fingerprint"], &1["run_id"]}) == [
               {"shown", shown.fingerprint, run["id"]},
               {"rejected", rejected.fingerprint, run["id"]}
             ]
    end

    test "dismissed findings are not reported again", %{history: history} do
      script = script(%{findings: [nil_check()]})
      assert {:ok, first} = review(change(), script, history: history)
      [%Finding{fingerprint: fingerprint}] = first.blocking

      # Shown findings are reported again by default.
      assert {:ok, again} = review(change(), script, history: history)
      assert [%Finding{fingerprint: ^fingerprint}] = again.blocking

      :ok = History.record_outcome(history, fingerprint, :dismissed)
      _ = calls(:verifier)

      assert {:ok, third} = review(change(), script, history: history)
      assert third.blocking == []
      assert [%{reason: :known, finding: %Finding{fingerprint: ^fingerprint}}] = third.dropped
      assert calls(:verifier) == []

      # The skipped run is recorded too, without shown findings.
      assert {:ok, [_, _, _]} = History.runs(history)
      assert {:ok, events} = History.finding_events(history)
      assert Enum.map(events, & &1["event"]) == ["shown", "shown", "dismissed"]
    end

    test "with :shown among the skipped outcomes, only new findings are reported", %{
      history: history
    } do
      script = script(%{findings: [nil_check()]})
      opts = [history: history, skip_outcomes: [:shown, :dismissed]]
      assert {:ok, %Result{blocking: [_shown]}} = review(change(), script, opts)

      assert {:ok, second} = review(change(), script, opts)
      assert second.blocking == []
      assert [%{reason: :known}] = second.dropped
      assert second.summary.verdict == :clean
    end

    test "an unusable history is a warning, not a failure" do
      home = Tackle.Test.Runtime.tmp_home()
      blocked = Path.join(home, "file")
      File.write!(blocked, "")
      {:ok, history} = History.open("/repo", home: blocked)

      assert {:ok, result} =
               review(change(), script(%{findings: [nil_check()]}), history: history)

      assert [%Finding{}] = result.blocking
      # Its home is a file: neither reading nor writing works.
      assert [read, write] = result.summary.warnings
      assert read =~ "review history could not be read: cannot read"
      assert write =~ "review history could not be written: cannot create"

      {:ok, unreadable} = History.open("/repo", home: home)
      File.mkdir_p!(History.findings_path(unreadable))

      assert {:ok, result} =
               review(change(), script(%{findings: [nil_check()]}), history: unreadable)

      assert [%Finding{}] = result.blocking
      assert [read_warning, write_warning] = result.summary.warnings
      assert read_warning =~ "review history could not be read: cannot read"
      assert write_warning =~ "review history could not be written: cannot write"
    end

    test "options are validated", %{history: history} do
      profiles = profiles(script())
      scope = start_scope(root: [allow_delegation: true], profiles: profiles)
      base = [requester: handle(scope), profiles: profiles]

      assert {:error, {:invalid_option, :history, "/repo"}} =
               Review.run(change(), [history: "/repo"] ++ base)

      assert {:error, {:invalid_option, :skip_outcomes, [:great]}} =
               Review.run(change(), [history: history, skip_outcomes: [:great]] ++ base)

      refute_received {:llm_call, _stage, _request}
    end
  end

  test "samples review each unit several times and merge what they agree on" do
    script = script(%{findings: [nil_check()]})

    assert {:ok, result} = review(change(), script, samples: 2, scorer: nil)
    assert [%Finding{support: 2, confidence: 0.7}] = result.blocking
    assert result.summary.detected == 2

    first_calls = Enum.filter(calls(:detector), &(&1.tool_results == []))
    assert [_, _, _, _, _, _] = first_calls
    assert calls(:scorer) == []
  end

  test "per-stage models override the profiles' models" do
    script = script(%{findings: [nil_check()]})

    assert {:ok, _result} =
             review(change(), script, models: [detector: "review/other", scorer: "review/other"])

    assert Enum.all?(calls(:detector), &(&1.model == "other"))
    assert Enum.all?(calls(:verifier), &(&1.model == "fake"))
    assert [%{model: "other"}] = calls(:scorer)
  end

  test "the scorer follows the requester's current model like the verifier" do
    script = script(%{findings: [nil_check()]})
    inherit = [model_source: :parent]
    profiles = profiles(script, detector: inherit, verifier: inherit)

    {:ok, root_config} =
      Config.new(
        adapters: [Adapter],
        model: "review/fake",
        system_prompt: "Root.",
        llm_opts: [test_pid: self(), script: script]
      )

    spec =
      ScopeSpec.new!(
        root_spec: AgentSpec.new!(name: "root", config: root_config, allow_delegation: true),
        profiles: profiles
      )

    {:ok, scope} = Tackle.Runtime.start_scope(spec)
    on_exit(fn -> Tackle.Test.Runtime.stop_scope(scope.scope_ref) end)

    # The requester switches models after its scope (and profiles) started.
    assert {:ok, _snapshot} =
             Tackle.Runtime.reconfigure(scope.root_agent_ref, model: "review/other")

    opts = [requester: scope.root_agent_ref, profiles: profiles, rules: rules()]

    assert {:ok, %Result{blocking: [_finding]}} = Review.run(change(), opts)
    assert Enum.all?(calls(:detector), &(&1.model == "other"))
    assert Enum.all?(calls(:verifier), &(&1.model == "other"))
    assert [%{model: "other"}] = calls(:scorer)

    # A per-stage verifier model applies to the scorer too.
    assert {:ok, _result} = Review.run(change(), [models: [verifier: "review/fake"]] ++ opts)
    assert Enum.all?(calls(:detector), &(&1.model == "other"))
    assert Enum.all?(calls(:verifier), &(&1.model == "fake"))
    assert [%{model: "fake"}] = calls(:scorer)
  end

  test "a failing scorer keeps the detector's confidence" do
    script = script(%{findings: [nil_check()], scorer: fn _request -> {:error, :overloaded} end})

    assert {:ok, result} = review(change(), script)
    assert [%Finding{confidence: 0.7}] = result.blocking
    assert [%{reason: :overloaded}] = result.summary.scoring_failures
  end

  test "runs with the review profiles of a coding scope" do
    home = Tackle.Test.Runtime.tmp_home()
    cwd = Path.join(home, "project")
    File.mkdir_p!(cwd)

    {:ok, spec} =
      Tackle.Coding.scope_spec(
        available_adapters: [Adapter],
        cwd: cwd,
        env: %{"TACKLE_HOME" => home},
        overrides: [
          model: "review/fake",
          llm_opts: [test_pid: self(), script: script(%{findings: [nil_check()]})],
          retry: false
        ]
      )

    {:ok, scope} = Tackle.Runtime.start_scope(spec)
    on_exit(fn -> Tackle.Test.Runtime.stop_scope(scope.scope_ref) end)

    assert {:ok, result} =
             Review.run(change(),
               requester: scope.root_agent_ref,
               profiles: spec.profiles,
               rules: rules()
             )

    assert [%Finding{verdict: :confirmed, confidence: 0.9}] = result.blocking
    [call | _] = calls(:detector)
    assert call.model == "fake"
  end

  describe "options" do
    test "are validated before anything runs" do
      profiles = profiles(script())
      scope = start_scope(root: [allow_delegation: true], profiles: profiles)
      base = [requester: handle(scope), profiles: profiles]

      assert {:error, {:missing_option, :requester}} =
               Review.run(change(), Keyword.delete(base, :requester))

      assert {:error, {:unknown_options, [:bogus]}} = Review.run(change(), [bogus: 1] ++ base)

      assert {:error, {:missing_profile, "review-verifier"}} =
               Review.run(
                 change(),
                 Keyword.put(base, :profiles, Map.delete(profiles, "review-verifier"))
               )

      no_tool =
        Map.put(
          profiles,
          "review-detector",
          stage_spec("review-detector", ReportVerdict, script())
        )

      assert {:error, {:missing_tool, "review-detector", "report_findings"}} =
               Review.run(change(), Keyword.put(base, :profiles, no_tool))

      assert {:error, {:invalid_option, :profile, :loud}} =
               Review.run(change(), [profile: :loud] ++ base)

      assert {:error, {:invalid_option, :samples, 0}} = Review.run(change(), [samples: 0] ++ base)

      assert {:error, {:invalid_option, :models, _}} =
               Review.run(change(), [models: [writer: "review/fake"]] ++ base)

      assert {:error, {:invalid_option, :models, {:scorer, "nope/x", _reason}}} =
               Review.run(change(), [models: [scorer: "nope/x"]] ++ base)

      assert {:error, {:invalid_glob, _, _}} =
               Review.run(change(), [exclude: ["["], rules: []] ++ base)

      refute_received {:llm_call, _stage, _request}
    end
  end
end
