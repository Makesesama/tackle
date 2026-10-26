defmodule Tackle.Workflow.ClassifyTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import Tackle.Workflow.TestSupport

  alias Tackle.Lib.Decision.{Answer, Question, Request, Result}
  alias Tackle.Lib.LLM.Provider
  alias Tackle.Workflow
  alias Tackle.Workflow.Decisions
  alias Tackle.Workflow.Tool, as: WorkflowTool

  @workflow_timeout 5_000

  # Answers every question deterministically and reports the request to the
  # test process. `:reply` in the options replaces the answer.
  defmodule Judge do
    @moduledoc false

    def answer(%Request{} = request, opts) do
      if pid = Keyword.get(opts, :test_pid), do: send(pid, {:decide, request})

      case Keyword.get(opts, :reply) do
        nil -> {:ok, %Result{answers: Map.new(request.questions, &answer/1), usage: usage(opts)}}
        :raise -> raise "judge exploded"
        :throw -> throw(:judge_threw)
        :exit -> exit(:judge_exited)
        reply -> reply
      end
    end

    defp usage(opts), do: Keyword.get(opts, :usage, %{"input_tokens" => 20, "output_tokens" => 5})

    defp answer(%Question{name: name, type: :choice}) do
      {name,
       %Answer{
         type: :choice,
         choice: "approve",
         probabilities: %{"approve" => 0.9, "revise" => 0.1},
         confidence: 0.8
       }}
    end

    defp answer(%Question{name: name, type: :noul}),
      do: {name, %Answer{type: :noul, noul: 0.25}}

    defp answer(%Question{name: name, type: :score}),
      do: {name, %Answer{type: :score, score: 1, probabilities: %{0 => 0.1, 1 => 0.7, 2 => 0.2}}}
  end

  defmodule LocalJudge do
    @moduledoc false
    @behaviour Tackle.Lib.Decision

    def adapter_id, do: "local"

    @impl true
    def decision_models, do: ["judge"]

    @impl true
    def decide(request, opts), do: Judge.answer(request, opts)

    @impl true
    def local?, do: true
  end

  defmodule CloudJudge do
    @moduledoc false
    @behaviour Tackle.Lib.Decision

    def adapter_id, do: "cloud"

    @impl true
    def decision_models, do: ["judge"]

    @impl true
    def decide(request, opts), do: Judge.answer(request, opts)
  end

  defmodule BadFlagJudge do
    @moduledoc false
    def adapter_id, do: "bad"
    def decision_models, do: ["judge"]
    def decide(request, opts), do: Judge.answer(request, opts)
    def local?, do: :maybe
  end

  # One adapter backing several providers: settings choose models and locality.
  defmodule InstanceJudge do
    @moduledoc false
    def adapter_id, do: "instance"
    def decision_models(settings), do: Map.fetch!(settings, "models")
    def local?(settings), do: Map.get(settings, "local", false)

    def decide(request, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:provider, opts[:provider_id], opts[:provider_settings]}
      )

      Judge.answer(request, opts)
    end
  end

  defmodule ChatOnly do
    @moduledoc false
    def adapter_id, do: "chat"
  end

  @verdict """
  {verdict = {type = "choice", instructions = "Does the review approve?",
              criteria = {approve = "No blocking findings", revise = "Blocking findings"}}}
  """

  defp decisions(opts \\ []) do
    [
      providers: [ChatOnly, LocalJudge, CloudJudge],
      options: Keyword.merge([test_pid: self()], Keyword.get(opts, :options, [])),
      default_model: Keyword.get(opts, :default_model, "local/judge")
    ]
  end

  defp run(script, opts \\ []) do
    scope = start_scope()

    with {:ok, ref} <- Workflow.run(scope.root_agent_ref, script, opts) do
      Workflow.await(ref, @workflow_timeout)
    end
  end

  describe "answers" do
    test "translates every question type and reports the selected model" do
      script = """
      local c = tackle.classify({review = "looks good", files = {"a.ex", "b.ex"}}, {
        verdict = {type = "choice", instructions = "Approve?", criteria = {"approve", "revise"}},
        tests = {type = "noul", instructions = "Tests added?",
                 criteria = {[true] = "Yes", ["false"] = "No"}},
        quality = {type = "score", instructions = "Rate it.", criteria = {"poor", "fair", "good"}}
      })
      local v, t, q = c.answers.verdict, c.answers.tests, c.answers.quality
      return c.ok, c.status, c.model, c.tokens, v.choice, v.probability, v.probabilities.revise,
        v.confidence, t.noul, q.score, q.probabilities[1], q.probabilities[3]
      """

      assert {:ok, [true, "ok", "local/judge", 0, "approve", 0.9, 0.1, 0.8, 0.25, 2, 0.1, 0.2]} =
               run(script, decisions: decisions())

      assert_receive {:decide, %Request{} = request}
      assert request.model == "judge"
      assert request.state == %{"review" => "looks good", "files" => ["a.ex", "b.ex"]}
      assert Enum.map(request.questions, & &1.name) == ["quality", "tests", "verdict"]

      assert %{
               "quality" => %Question{type: :score, criteria: ["poor", "fair", "good"]},
               "tests" => %Question{type: :noul, criteria: %{"true" => "Yes", "false" => "No"}},
               "verdict" => %Question{
                 type: :choice,
                 criteria: %{"approve" => nil, "revise" => nil}
               }
             } = Map.new(request.questions, &{&1.name, &1})
    end

    test "an explicit model selects among the granted adapters" do
      script = """
      local c = tackle.classify("a review", #{@verdict}, {model = "cloud/judge"})
      return c.model, c.answers.verdict.choice
      """

      assert {:ok, ["cloud/judge", "approve"]} = run(script, decisions: decisions())
      assert_receive {:decide, %Request{state: "a review", model: "judge"}}
    end

    test "a model that cannot answer returns a failure instead of raising" do
      script = """
      local c = tackle.classify("a review", #{@verdict})
      return c.ok, c.status, c.text, c.tokens, c.answers
      """

      assert {:ok, [false, "error", "classification failed: :overloaded", 0, nil]} =
               run(script, decisions: decisions(options: [reply: {:error, :overloaded}]))

      assert {:ok, [false, "cancelled", "classification cancelled", 0, nil]} =
               run(script, decisions: decisions(options: [reply: {:error, :cancelled}]))

      assert {:ok, [false, "error", "classification failed: " <> text, 0, nil]} =
               run(script, decisions: decisions(options: [reply: :raise]))

      assert text =~ "judge exploded"

      for {reply, reason} <- [throw: "throw :judge_threw", exit: "exit :judge_exited"] do
        assert {:ok, [false, "error", "classification failed: " <> text, 0, nil]} =
                 run(script, decisions: decisions(options: [reply: reply]))

        assert text =~ "The decision adapter #{inspect(LocalJudge)} failed: #{reason}"
      end
    end

    test "answers that do not match the questions are failures that still report spent tokens" do
      script = """
      local c = tackle.classify("a review", #{@verdict}, {model = "cloud/judge"})
      return c.ok, c.status, c.text, c.tokens, tackle.budget().used
      """

      wrong_type = %Result{
        answers: %{"verdict" => %Answer{type: :noul, noul: 0.5}},
        usage: %{"total_tokens" => 7}
      }

      assert {:ok, [false, "error", text, 7, 7]} =
               run(script, decisions: decisions(options: [reply: {:ok, wrong_type}]))

      assert text ==
               ~s(classification failed: Invalid decision response: ) <>
                 ~s({:invalid_answer, "verdict", :type})

      missing = %Result{answers: %{}, usage: %{"total_tokens" => 3}}

      assert {:ok, [false, "error", text, 3, 3]} =
               run(script, decisions: decisions(options: [reply: {:ok, missing}]))

      assert text =~ ~s({:missing_answer, "verdict"})

      # An answer the old re-check accepted but that is outside the options.
      unknown = %Result{
        answers: %{"verdict" => %Answer{type: :choice, choice: "maybe"}},
        usage: %{"total_tokens" => 2}
      }

      assert {:ok, [false, "error", text, 2, 2]} =
               run(script, decisions: decisions(options: [reply: {:ok, unknown}]))

      assert text =~ ~s({:invalid_answer, "verdict", :choice})
    end

    test "long lists keep their order" do
      script = """
      local items = {}
      for i = 1, 40 do items[i] = "finding " .. i end
      local c = tackle.classify({findings = items}, #{@verdict})
      return c.ok
      """

      assert {:ok, [true]} = run(script, decisions: decisions())
      assert_receive {:decide, %Request{state: %{"findings" => findings}}}
      assert findings == Enum.map(1..40, &"finding #{&1}")
    end
  end

  describe "token budget" do
    test "remote classifications count against the budget and are refused once it is spent" do
      script = """
      local first = tackle.classify("a review", #{@verdict}, {model = "cloud/judge"})
      local used = tackle.budget().used
      local refused, err = pcall(tackle.classify, "a review", #{@verdict}, {model = "cloud/judge"})
      local local_call = tackle.classify("a review", #{@verdict})
      return first.tokens, used, refused, err, local_call.ok, local_call.tokens, tackle.budget().used
      """

      assert {:ok, [25, 25, false, err, true, 0, 25]} =
               run(script, decisions: decisions(), token_budget: 10)

      assert err =~ "token budget exhausted (used 25 of 10 tokens)"
    end

    test "local classifications never touch the budget" do
      script = """
      local c = tackle.classify("a review", #{@verdict})
      return c.tokens, tackle.budget().used
      """

      assert {:ok, [0, 0]} =
               run(script,
                 decisions: decisions(options: [usage: %{"total_tokens" => 999}]),
                 token_budget: 10
               )
    end
  end

  describe "progress" do
    defp observe(test_pid \\ self()), do: fn event -> send(test_pid, {:progress, event}) end

    defp classify_events do
      receive do
        {:progress, %{type: type} = event} when type in [:classify_started, :classify_finished] ->
          [event | classify_events()]

        {:progress, _other} ->
          classify_events()
      after
        0 -> []
      end
    end

    test "a classification reports its start and its answers, labelled by the script" do
      script = """
      local c = tackle.classify("a review", {
        verdict = {type = "choice", instructions = "Approve?", criteria = {"revise", "approve"}},
        tests = {type = "noul", instructions = "Tests added?"},
        quality = {type = "score", instructions = "Rate it.", criteria = {"poor", "fair", "good"}}
      }, {model = "cloud/judge", label = "review gate"})
      return c.ok
      """

      assert {:ok, [true]} = run(script, decisions: decisions(), on_event: observe())

      assert [
               %{
                 type: :classify_started,
                 id: id,
                 label: "review gate",
                 model: "cloud/judge",
                 local: false,
                 questions: [
                   %{name: "quality", type: :score, options: ["poor", "fair", "good"]},
                   %{name: "tests", type: :noul, options: nil},
                   %{name: "verdict", type: :choice, options: ["approve", "revise"]}
                 ]
               },
               %{
                 type: :classify_finished,
                 id: id,
                 label: "review gate",
                 ok: true,
                 status: :ok,
                 tokens: 25,
                 text: nil,
                 answers: %{
                   "verdict" => %{
                     "choice" => "approve",
                     "probability" => 0.9,
                     "probabilities" => %{"approve" => 0.9, "revise" => 0.1}
                   },
                   "tests" => %{"type" => "noul", "noul" => 0.25},
                   "quality" => %{"score" => 2, "probabilities" => %{1 => 0.1, 2 => 0.7}}
                 }
               }
             ] = classify_events()
    end

    test "a classification the model cannot answer reports its failure" do
      script = "return tackle.classify('a review', #{@verdict}).status"

      assert {:ok, ["error"]} =
               run(script,
                 decisions: decisions(options: [reply: {:error, :overloaded}]),
                 on_event: observe()
               )

      assert [
               %{type: :classify_started, id: id, label: nil, model: "local/judge", local: true},
               %{
                 type: :classify_finished,
                 id: id,
                 ok: false,
                 status: :error,
                 tokens: 0,
                 answers: nil,
                 text: "classification failed: :overloaded"
               }
             ] = classify_events()
    end

    test "each call gets its own id" do
      script = """
      tackle.classify('a', #{@verdict})
      tackle.classify('b', #{@verdict})
      """

      assert {:ok, []} = run(script, decisions: decisions(), on_event: observe())

      assert [
               %{type: :classify_started, id: first},
               %{type: :classify_finished, id: first},
               %{type: :classify_started, id: second},
               %{type: :classify_finished, id: second}
             ] = classify_events()

      assert first != second
    end

    test "a classification that raises reports nothing" do
      script = """
      local ok = pcall(tackle.classify, 'x', {v = {type = 'vote', instructions = 'x'}})
      local spent = pcall(tackle.classify, 'x', #{@verdict}, {model = 'cloud/judge'})
      local again = pcall(tackle.classify, 'x', #{@verdict}, {model = 'cloud/judge'})
      return ok, spent, again
      """

      assert {:ok, [false, true, false]} =
               run(script, decisions: decisions(), on_event: observe(), token_budget: 10)

      assert [%{type: :classify_started}, %{type: :classify_finished, ok: true}] =
               classify_events()
    end

    test "the label must be a non-empty string" do
      for label <- ["''", "42", "{}"] do
        script = """
        local ok, err = pcall(tackle.classify, 'x', #{@verdict}, {label = #{label}})
        return ok, err
        """

        assert {:ok, [false, message]} = run(script, decisions: decisions())
        assert message =~ "classify option label must be a non-empty string"
      end
    end

    test "the run_workflow tool forwards classifications as workflow_progress events" do
      scope = start_scope()
      test_pid = self()

      context = %{
        runtime: scope.root_agent_ref,
        tool_call_id: "call-1",
        decisions: Map.new(decisions()),
        event_callback: fn event -> send(test_pid, {:event, event}) end
      }

      script = "return tackle.classify('x', #{@verdict}, {label = 'gate'}).ok"
      assert {:ok, "true"} = WorkflowTool.run(%{"script" => script}, context)

      assert_received {:event,
                       %Tackle.Lib.Event{
                         type: :workflow_progress,
                         data: %{kind: :classify_started, tool_call_id: "call-1", label: "gate"}
                       }}

      assert_received {:event,
                       %Tackle.Lib.Event{
                         type: :workflow_progress,
                         data: %{kind: :classify_finished, tool_call_id: "call-1", ok: true}
                       }}
    end
  end

  describe "errors" do
    test "a workflow without decision models raises" do
      assert {:error, %{message: message}} = run("return tackle.classify('x', #{@verdict})")
      assert message =~ "no decision models are available in this session"
    end

    test "an unknown model raises and lists the available ones" do
      script = "return tackle.classify('x', #{@verdict}, {model = 'cloud/missing'})"

      assert {:error, %{message: message}} = run(script, decisions: decisions())

      assert message =~
               ~s[decision model "cloud/missing" is not available (available: cloud/judge, local/judge)]
    end

    test "a model of an unknown provider raises and lists the available ones" do
      script = "return tackle.classify('x', #{@verdict}, {model = 'gone/judge'})"

      assert {:error, %{message: message}} = run(script, decisions: decisions())
      assert message =~ ~s[decision model "gone/judge" is not available (available: ]
    end

    test "a missing model without a default raises" do
      grant = Keyword.put(decisions(), :default_model, nil)

      assert {:error, %{message: message}} =
               run("return tackle.classify('x', #{@verdict})", decisions: grant)

      assert message =~ "no default decision model is configured; pass {model = ...}"
    end

    test "a misconfigured adapter is reported as such, not as an unknown model" do
      grant = [providers: [BadFlagJudge], default_model: nil]
      script = "return tackle.classify('x', #{@verdict}, {model = 'bad/judge'})"

      assert {:error, %{message: message}} = run(script, decisions: grant)

      assert message =~
               ~s(decision model "bad/judge" could not be selected: {:invalid_local_flag, "bad", :maybe})

      assert {:error, %{message: message}} =
               run("return tackle.classify('x', #{@verdict}, {model = 'nope'})",
                 decisions: decisions()
               )

      assert message =~ ~s(decision model "nope" is not a "provider/model" reference)
    end

    test "malformed arguments raise catchable errors" do
      cases = [
        {"tackle.classify('x', {})", "questions must be a non-empty table"},
        {"tackle.classify('x', {v = {type = 'vote', instructions = 'x'}})",
         ~s(question "v" needs type "choice", "noul", or "score")},
        {"tackle.classify('x', {v = {type = 'noul', instructions = 'x', extra = 1}})",
         ~s(question "v" has unknown keys: "extra")},
        {"tackle.classify('x', {v = {type = 'noul', instructions = ''}})",
         ~s(question "v" needs non-empty instructions)},
        {"tackle.classify('x', {v = {type = 'choice', instructions = 'x', criteria = {'only'}}})",
         ~s(question "v" needs 2 to 24 options or levels, got 1)},
        {"tackle.classify('x', {v = {type = 'choice', instructions = 'x', criteria = {" <>
           Enum.map_join(1..40, ", ", &"'o#{&1}'") <> "}}})",
         ~s(question "v" needs 2 to 24 options or levels, got 40)},
        {"tackle.classify('x', {v = {type = 'score', instructions = 'x', criteria = {a = 'b'}}})",
         "score criteria must be a list of levels"},
        {"tackle.classify({}, {v = {type = 'noul', instructions = 'x'}})",
         "state must not be empty"},
        {"tackle.classify(42, {v = {type = 'noul', instructions = 'x'}})",
         "state must be a string or a table"},
        {"tackle.classify({f = print}, {v = {type = 'noul', instructions = 'x'}})",
         "state must hold only strings"},
        {"tackle.classify('x', {v = {type = 'noul', instructions = 'x'}}, {limit = 1})",
         ~s(unknown classify options: "limit")},
        {"tackle.classify('x', {v = {type = 'noul', instructions = 'x'}}, {model = ''})",
         "classify option model must be a non-empty string"}
      ]

      for {call, expected} <- cases do
        script = "local ok, err = pcall(function() return #{call} end) return ok, err"
        assert {:ok, [false, message]} = run(script, decisions: decisions())
        assert message =~ expected, "#{call}: #{message}"
      end

      refute_received {:decide, _request}
    end

    test "an invalid grant fails the workflow before it starts" do
      scope = start_scope()

      assert {:error, {:unknown_decision_model, "local/missing"}} =
               Workflow.run(scope.root_agent_ref, "return 1",
                 decisions: [providers: [LocalJudge], default_model: "local/missing"]
               )

      assert {:error, {:invalid_workflow_option, :decisions, [unknown: [:model]]}} =
               Workflow.run(scope.root_agent_ref, "return 1", decisions: [model: "local/judge"])

      assert {:error, {:invalid_workflow_option, :decisions, "bad"}} =
               Workflow.run(scope.root_agent_ref, "return 1", decisions: "bad")
    end
  end

  describe "grant" do
    test "lists the decision models its adapters offer" do
      assert {:ok, %Decisions{} = grant} = Decisions.new(decisions())
      assert Decisions.available(grant) == ["cloud/judge", "local/judge"]
      assert {:ok, nil} = Decisions.new(nil)
    end

    test "providers of one adapter keep their own models, locality, and settings" do
      home = %{"models" => ["small"], "local" => true}
      cloud = %{"models" => ["large"]}

      grant = [
        providers: [
          %Provider{id: "judge-home", adapter: InstanceJudge, settings: home},
          %Provider{id: "judge-cloud", adapter: InstanceJudge, settings: cloud}
        ],
        options: [test_pid: self()],
        default_model: "judge-home/small"
      ]

      assert {:ok, %Decisions{} = decisions} = Decisions.new(grant)
      assert Decisions.available(decisions) == ["judge-cloud/large", "judge-home/small"]

      assert {:ok, %{local: true, provider_id: "judge-home"}} = Decisions.select(decisions, nil)

      assert {:ok, %{local: false, provider_id: "judge-cloud"}} =
               Decisions.select(decisions, "judge-cloud/large")

      assert {:error, {:unknown_decision_model, "judge-home/large"}} =
               Decisions.select(decisions, "judge-home/large")

      script = "return tackle.classify('x', #{@verdict}, {model = 'judge-cloud/large'}).tokens"
      assert {:ok, [25]} = run(script, decisions: grant)
      assert_receive {:provider, "judge-cloud", ^cloud}

      assert {:error, {:duplicate_provider_id, "judge-home"}} =
               Decisions.new(
                 providers: [
                   %Provider{id: "judge-home", adapter: InstanceJudge, settings: home},
                   %Provider{id: "judge-home", adapter: InstanceJudge, settings: cloud}
                 ]
               )
    end
  end

  describe "run_workflow tool" do
    test "takes the grant from the session context" do
      scope = start_scope()

      context = %{runtime: scope.root_agent_ref, decisions: Map.new(decisions())}
      script = "return tackle.classify('x', #{@verdict}).answers.verdict.choice"

      assert {:ok, "approve"} = WorkflowTool.run(%{"script" => script}, context)
    end

    test "reports a malformed grant" do
      scope = start_scope()

      assert {:error, "decisions are misconfigured: " <> _reason} =
               WorkflowTool.run(%{"script" => "return 1"}, %{
                 runtime: scope.root_agent_ref,
                 decisions: %{providers: "nope"}
               })
    end
  end
end
