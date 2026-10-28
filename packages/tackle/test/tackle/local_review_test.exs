defmodule Tackle.LocalReviewTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import Tackle.Test.Runtime, only: [start_scope: 1]

  alias Tackle.Config
  alias Tackle.Executor
  alias Tackle.Lib.Cancellation
  alias Tackle.LocalReview
  alias Tackle.LocalReview.History
  alias Tackle.Review
  alias Tackle.Review.{Change, Diff, Finding, Result, Rules}
  alias Tackle.Review.Tools.{ReportFindings, ReportVerdict}
  alias Tackle.Runtime.{AgentSpec, RootBackend, ScopeSpec}

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
        model: Keyword.fetch!(opts, :model),
        reasoning_effort: Keyword.get(opts, :reasoning_effort),
        prompt_cache_key: Keyword.get(opts, :prompt_cache_key)
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

    # Findings reported while the run keeps reviewing.
    defp reply({:progress, findings}, opts, _test_pid),
      do: tool_call("report_findings", %{"findings" => findings, "done" => false}, opts)

    # One verdict for every finding of the run.
    defp reply({:verdict, verdict, evidence}, opts, test_pid) do
      verdicts = for {id, _text} <- finding_blocks(opts), do: {id, verdict, evidence}
      reply({:verdicts, verdicts}, opts, test_pid)
    end

    defp reply({:verdicts, verdicts}, opts, _test_pid) do
      calls =
        Enum.map(verdicts, fn {id, verdict, evidence} ->
          call("report_verdict", %{"finding" => id, "verdict" => verdict, "evidence" => evidence})
        end)

      response(%{"content" => nil, "tool_calls" => calls}, opts)
    end

    defp reply({:answer, text}, opts, _test_pid),
      do: response(%{"content" => text, "tool_calls" => []}, opts)

    # The same confidence for every comment of the batch.
    defp reply({:confidence, value}, opts, _test_pid) do
      ids = Regex.scan(~r/<comment id="(C\d+)"/, user_prompt(opts), capture: :all_but_first)
      scores = for [id] <- ids, do: %{"id" => id, "confidence" => value}
      response(%{"scores" => scores}, opts)
    end

    defp reply({:error, reason}, _opts, _test_pid), do: {:error, reason}

    defp reply(:block, opts, test_pid) do
      if Cancellation.cancelled?(Keyword.get(opts, :cancellation_signal)) do
        {:error, :cancelled}
      else
        Process.sleep(10)
        reply(:block, opts, test_pid)
      end
    end

    defp tool_call(name, arguments, opts),
      do: response(%{"content" => nil, "tool_calls" => [call(name, arguments)]}, opts)

    defp call(name, arguments),
      do: %{
        "id" => "call-#{System.unique_integer([:positive])}",
        "name" => name,
        "arguments" => arguments
      }

    @doc false
    def finding_blocks(%{prompt: prompt}), do: blocks(prompt)
    def finding_blocks(opts) when is_list(opts), do: blocks(user_prompt(opts))

    defp blocks(prompt) do
      for [id, text] <-
            Regex.scan(~r/<finding id="(F\d+)">(.*?)<\/finding>/s, prompt,
              capture: :all_but_first
            ),
          do: {id, text}
    end

    defp user_prompt(opts) do
      opts
      |> Keyword.get(:messages, [])
      |> Enum.find_value("", fn
        %{role: :user, content: content} -> content
        _other -> nil
      end)
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
      diff: diff
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

        # A run is stopped once it has reported everything, so the closing
        # answer it would write next is never needed.
        _request ->
          :block
      end,
      verifier: fn
        %{tool_results: []} = request ->
          {:verdicts,
           for {id, text} <- Adapter.finding_blocks(request) do
             if text =~ "Guard against",
               do: {id, "confirmed", "lib/a.ex:3 reads map.key unguarded."},
               else: {id, "rejected", "Naming is not a defect."}
           end}

        _request ->
          :block
      end,
      scorer: fn _request -> {:confidence, 0.9} end
    }

    handlers = Map.merge(defaults, overrides)
    fn stage, request -> Map.fetch!(handlers, stage).(request) end
  end

  defp stage_spec(name, tool, script, opts) do
    {:ok, config} =
      Config.new(
        providers: [Adapter],
        model: "review/fake",
        tools: [tool],
        system_prompt: "Review stage.",
        max_iterations: Keyword.get(opts, :max_iterations, 6),
        llm_opts: [test_pid: self(), script: script]
      )

    AgentSpec.new!(
      name: name,
      config: config,
      timeout: Keyword.get(opts, :timeout, 5_000),
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

  # Runs a review through `Tackle.LocalReview` from a fresh scope's root.
  defp local_review(change, script, opts) do
    profiles = profiles(script)
    scope = start_scope(root: [allow_delegation: true], profiles: profiles)

    LocalReview.run(
      change,
      Keyword.merge([requester: scope.root_agent_ref, profiles: profiles, rules: rules()], opts)
    )
  end

  defp calls(stage) do
    receive do
      {:llm_call, ^stage, request} -> [request | calls(stage)]
    after
      0 -> []
    end
  end

  describe "Tackle.LocalReview history" do
    setup do
      {:ok, history} = History.open("/repo", home: Tackle.Test.Runtime.tmp_home())
      {:ok, history: history}
    end

    test "records the run with its shown and rejected findings", %{history: history} do
      assert {:ok, result} = local_review(change(), script(), history: history)
      [shown] = result.blocking
      [%{finding: rejected}] = result.rejected
      assert result.summary.warnings == []

      assert {:ok, [run]} = History.runs(history)
      assert %{"blocking" => 1, "rejected" => 1, "candidates" => 2} = run["summary"]
      assert [%{"id" => "missing-nil-check", "status" => "active"}] = run["rules"]
      assert Map.keys(run["prompts"]) == ["review-detector", "review-verifier"]
      assert run["usage"]["input_tokens"] == 40
      assert %{"runs" => 2, "usage" => %{"input_tokens" => 20}} = run["stages"]["detector"]
      assert %{"runs" => 1} = run["stages"]["verifier"]
      assert is_integer(run["duration_ms"])

      assert %{"max_changed_lines" => 150, "pack_files" => true, "verify_batch" => 4} =
               run["settings"]

      assert run["settings"]["models"]["detector"] == "review/fake"

      assert {:ok, events} = History.finding_events(history)

      assert Enum.map(events, &{&1["event"], &1["fingerprint"], &1["run_id"]}) == [
               {"shown", shown.fingerprint, run["id"]},
               {"rejected", rejected.fingerprint, run["id"]}
             ]
    end

    test "dismissed findings are not reported again", %{history: history} do
      script = script(%{findings: [nil_check()]})
      assert {:ok, first} = local_review(change(), script, history: history)
      [%Finding{fingerprint: fingerprint}] = first.blocking

      # Shown findings are reported again by default.
      assert {:ok, again} = local_review(change(), script, history: history)
      assert [%Finding{fingerprint: ^fingerprint}] = again.blocking

      :ok = History.record_outcome(history, fingerprint, :dismissed)
      _ = calls(:verifier)

      assert {:ok, third} = local_review(change(), script, history: history)
      assert third.blocking == []
      assert [%{reason: :known, finding: %Finding{fingerprint: ^fingerprint}}] = third.dropped
      assert calls(:verifier) == []

      # The skipped run is recorded too, without shown findings.
      assert {:ok, [_, _, _]} = History.runs(history)
      assert {:ok, events} = History.finding_events(history)
      assert Enum.map(events, & &1["event"]) == ["shown", "shown", "dismissed"]
    end

    test "open_history/2 opens the change's history or says why it cannot" do
      home = Tackle.Test.Runtime.tmp_home()
      assert {%History{} = history, []} = LocalReview.open_history(change(), home: home)
      assert history.root == "/repo"
      assert history.dir == Path.join([home, "review", history.project_key])

      assert LocalReview.open_history(change(), home: 42) ==
               {nil, ["Review history is unavailable: {:invalid_home, 42}"]}
    end

    test "an unusable history is a warning, not a failure" do
      home = Tackle.Test.Runtime.tmp_home()
      blocked = Path.join(home, "file")
      File.write!(blocked, "")
      {:ok, history} = History.open("/repo", home: blocked)

      assert {:ok, result} =
               local_review(change(), script(%{findings: [nil_check()]}), history: history)

      assert [%Finding{}] = result.blocking
      # Its home is a file: neither reading nor writing works.
      assert [read, write] = result.summary.warnings
      assert read =~ "review history could not be read: cannot read"
      assert write =~ "review history could not be written: cannot create"

      {:ok, unreadable} = History.open("/repo", home: home)
      File.mkdir_p!(History.findings_path(unreadable))

      assert {:ok, result} =
               local_review(change(), script(%{findings: [nil_check()]}), history: unreadable)

      assert [%Finding{}] = result.blocking
      assert [read_warning, write_warning] = result.summary.warnings
      assert read_warning =~ "review history could not be read: cannot read"
      assert write_warning =~ "review history could not be written: cannot write"
    end

    test "options are validated", %{history: history} do
      profiles = profiles(script())
      scope = start_scope(root: [allow_delegation: true], profiles: profiles)
      base = [requester: scope.root_agent_ref, profiles: profiles]

      assert {:error, {:invalid_option, :history, "/repo"}} =
               LocalReview.run(change(), [history: "/repo"] ++ base)

      # Options read here, before the review sees them, fail like its own.
      invalid = [
        known_fingerprints: 5,
        settings: :bogus,
        settings: %{default_rules: nil},
        warnings: :bogus,
        warnings: ["a", :b]
      ]

      for {key, value} <- invalid do
        assert LocalReview.run(change(), [{key, value} | base] ++ [history: history]) ==
                 {:error, {:invalid_option, key, value}}
      end

      # Rules are discovered through the session executor, so one is needed.
      assert {:error, {:missing_option, :executor}} = LocalReview.run(change(), base)

      # The history is local; the review itself does not accept it.
      assert {:error, {:unknown_options, [:history]}} =
               Review.run(change(), [history: history, rules: []] ++ base)

      refute_received {:llm_call, _stage, _request}
    end
  end

  describe "settings from the requester's session" do
    test "the requester session's review settings set stage thinking levels" do
      script = script(%{findings: [nil_check()]})
      inherit = [model_source: :parent]
      profiles = profiles(script, detector: inherit, verifier: inherit)

      {:ok, root_config} =
        Config.new(
          providers: [Adapter],
          model: "review/fake",
          thinking: "medium",
          system_prompt: "Root.",
          llm_opts: [test_pid: self(), script: script],
          review: [thinking: [detector: "low", scorer: "high"]]
        )

      spec =
        ScopeSpec.new!(
          backend: RootBackend,
          root_spec: AgentSpec.new!(name: "root", config: root_config, allow_delegation: true),
          profiles: profiles
        )

      {:ok, scope} = Tackle.Runtime.start_scope(spec)
      on_exit(fn -> Tackle.Test.Runtime.stop_scope(scope.scope_ref) end)
      opts = [requester: scope.root_agent_ref, profiles: profiles, rules: rules()]

      assert {:ok, result} = LocalReview.run(change(), opts)
      assert Enum.all?(calls(:detector), &(&1.reasoning_effort == "low"))
      assert Enum.all?(calls(:verifier), &(&1.reasoning_effort == "medium"))
      assert [%{reasoning_effort: "high"}] = calls(:scorer)

      assert %{detector: "low", verifier: "medium", scorer: "high"} =
               result.summary.settings.thinking

      # The option replaces a stage's setting; `nil` falls back to the
      # inherited level.
      assert {:ok, _result} =
               LocalReview.run(change(), [thinking: [detector: "minimal", scorer: nil]] ++ opts)

      assert Enum.all?(calls(:detector), &(&1.reasoning_effort == "minimal"))
      assert [%{reasoning_effort: "medium"}] = calls(:scorer)
    end

    test "the requester session's settings set profile, models, step limits, and rules" do
      script = script(%{findings: [nil_check()]})
      profiles = profiles(script)

      {:ok, root_config} =
        Config.new(
          providers: [Adapter],
          model: "review/fake",
          system_prompt: "Root.",
          llm_opts: [test_pid: self(), script: script],
          review: [
            profile: :assertive,
            models: [verifier: "review/other"],
            max_steps: [detector: 3, verifier: 2],
            default_rules: ["missing-nil-check"]
          ]
        )

      spec =
        ScopeSpec.new!(
          backend: RootBackend,
          root_spec: AgentSpec.new!(name: "root", config: root_config, allow_delegation: true),
          profiles: profiles
        )

      {:ok, scope} = Tackle.Runtime.start_scope(spec)
      on_exit(fn -> Tackle.Test.Runtime.stop_scope(scope.scope_ref) end)
      # Without `:rules`, the rules are discovered, built-in ones included.
      opts = [requester: scope.root_agent_ref, profiles: profiles, executor: Executor.local()]

      assert {:ok, result} = LocalReview.run(change(), opts)
      assert result.summary.profile == :assertive
      assert Enum.all?(calls(:verifier), &(&1.model == "other"))

      assert %{max_steps: %{detector: 3, verifier: 2}, models: %{verifier: "review/other"}} =
               result.summary.settings

      detector_prompts = Enum.map_join(calls(:detector), "\n", & &1.prompt)
      assert detector_prompts =~ ~s(<rule id="missing-nil-check")
      refute detector_prompts =~ ~s(<rule id="injection")

      # Options override the settings; a stage set to nil keeps its profile's limit.
      assert {:ok, result} =
               LocalReview.run(
                 change(),
                 [profile: :quiet, max_steps: [detector: nil], default_rules: []] ++ opts
               )

      assert result.summary.profile == :quiet
      assert %{max_steps: %{detector: 6, verifier: 2}} = result.summary.settings
      refute Enum.map_join(calls(:detector), "\n", & &1.prompt) =~ "<rule id="
    end

    test "discovers the user rules of the given Tackle home" do
      home = Tackle.Test.Runtime.tmp_home()
      rule = "---\nid: house-style\ncategory: correctness\nseverity: medium\n---\nCheck it.\n"
      File.mkdir_p!(Path.join(home, "review/rules"))
      File.write!(Path.join(home, "review/rules/house-style.md"), rule)

      profiles = profiles(script())
      scope = start_scope(root: [allow_delegation: true], profiles: profiles)

      opts = [
        requester: scope.root_agent_ref,
        profiles: profiles,
        executor: Executor.local(),
        home: home,
        user_home: nil,
        default_rules: []
      ]

      assert {:ok, _result} = LocalReview.run(change(), opts)
      assert Enum.map_join(calls(:detector), "\n", & &1.prompt) =~ ~s(<rule id="house-style")
    end

    test "a requester without a session fails before reading its settings" do
      script = script()
      profiles = profiles(script)
      scope = start_scope(root: [allow_delegation: true], profiles: profiles)
      requester = scope.root_agent_ref
      Tackle.Test.Runtime.stop_scope(scope.scope_ref)

      assert {:error, {:requester_unavailable, _reason}} =
               LocalReview.run(change(),
                 requester: requester,
                 profiles: profiles,
                 executor: Executor.local()
               )

      assert calls(:detector) == []
    end
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
end
