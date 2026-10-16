defmodule Tackle.Tools.ReviewTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import Tackle.Test.Runtime, only: [start_scope: 1, tmp_home: 0]

  alias Tackle.Config
  alias Tackle.Executor.Jailed
  alias Tackle.Lib.Tool
  alias Tackle.LocalReview.History
  alias Tackle.Review.Tools.{ReportFindings, ReportVerdict}
  alias Tackle.Runtime.{AgentSpec, Limits}
  alias Tackle.Test.{Gauge, GitRepo}

  defmodule Adapter do
    @moduledoc false
    # Scripted review stages: the detector reports one finding for lib/a.ex,
    # the verifier confirms it, and the scorer answers 0.9 (or the stage's
    # `:score` option). A root agent calls review_changes once and then
    # answers.

    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "tool-review"

    @impl true
    def models, do: ["fake"]

    @impl true
    def model_info(_model), do: %{context_window: 100_000, max_output_tokens: 1_000}

    @impl true
    def generate(schema, opts) do
      messages = Keyword.get(opts, :messages, [])
      prompt = Enum.find_value(messages, "", &(&1.role == :user && &1.content))
      answered? = Enum.any?(messages, &(&1.role == :tool))
      stage = stage(schema, prompt)

      send(Keyword.fetch!(opts, :test_pid), {:llm_call, stage})
      hold(stage, answered?, opts)

      {:ok,
       %{
         data: data(stage, answered?, prompt, opts),
         usage: %{input_tokens: 10, output_tokens: 5},
         model: "fake"
       }}
    end

    # A detector run with a gauge stays in flight so a test can see how many
    # run at once.
    defp hold(:detector, false, opts) do
      case Keyword.fetch(opts, :gauge) do
        {:ok, {gauge, expected}} -> Gauge.hold(gauge, expected)
        :error -> :ok
      end
    end

    defp hold(_stage, _answered?, _opts), do: :ok

    defp stage(schema, _prompt) when schema != nil, do: :scorer
    defp stage(nil, "Verify" <> _rest), do: :verifier
    defp stage(nil, prompt), do: if(prompt =~ "<unit id=", do: :detector, else: :root)

    defp data(:scorer, _answered?, _prompt, opts),
      do: %{"scores" => [%{"id" => "C1", "confidence" => Keyword.get(opts, :score, 0.9)}]}

    defp data(_stage, true, _prompt, _opts), do: %{"content" => "Done.", "tool_calls" => []}

    defp data(:detector, false, prompt, _opts),
      do: call("report_findings", %{"findings" => findings(prompt)})

    defp data(:verifier, false, _prompt, _opts), do: call("report_verdict", verdict())
    defp data(:root, false, _prompt, _opts), do: call("review_changes", %{})

    defp findings(prompt) do
      if prompt =~ ~s(<unit id="lib/a.ex#1">) do
        [
          %{
            "title" => "Guard against a missing key",
            "category" => "correctness",
            "severity" => "high",
            "blocking" => true,
            "confidence" => 0.8,
            "rule_id" => nil,
            "location" => %{
              "path" => "lib/a.ex",
              "side" => "new",
              "start_line" => 3,
              "end_line" => 3
            },
            "trigger" => "g/1 is called with a map without :key",
            "body" => "map.key raises KeyError for such maps.",
            "suggestion" => "def g(map), do: Map.get(map, :key)"
          }
        ]
      else
        []
      end
    end

    defp verdict,
      do: %{
        "finding" => "F1",
        "verdict" => "confirmed",
        "evidence" => "lib/a.ex:3 reads map.key unguarded."
      }

    defp call(name, arguments) do
      %{
        "content" => nil,
        "tool_calls" => [
          %{
            "id" => "call-#{System.unique_integer([:positive])}",
            "name" => name,
            "arguments" => arguments
          }
        ]
      }
    end
  end

  setup do
    repo = GitRepo.init("tool")
    GitRepo.write(repo, %{"lib/a.ex" => "defmodule A do\n  def f(x), do: x\nend\n"})
    GitRepo.commit(repo, "initial")
    GitRepo.git(repo, ["checkout", "-q", "-b", "feature"])

    GitRepo.write(repo, %{
      "lib/a.ex" => "defmodule A do\n  def f(x), do: x\n  def g(map), do: map.key\nend\n"
    })

    profiles = %{
      "review-detector" => stage_spec("review-detector", ReportFindings),
      "review-verifier" => stage_spec("review-verifier", ReportVerdict)
    }

    scope = start_scope(root: [allow_delegation: true], profiles: profiles)
    home = tmp_home()

    context = %{runtime: scope.root_agent_ref, cwd: repo, review_history: [home: home]}
    {:ok, repo: repo, scope: scope, home: home, context: context}
  end

  defp stage_spec(name, tool, llm_opts \\ []) do
    {:ok, config} =
      Config.new(
        providers: [Adapter],
        model: "tool-review/fake",
        tools: [tool],
        system_prompt: "Review stage.",
        max_iterations: 6,
        llm_opts: [test_pid: self()] ++ llm_opts
      )

    AgentSpec.new!(name: name, config: config, timeout: 5_000)
  end

  defp review(args, context), do: Tool.execute_tool_call(Tackle.Tools.Review, args, context)

  # The repository root as Git reports it, which keys the history.
  defp root(repo), do: repo |> GitRepo.git(["rev-parse", "--show-toplevel"]) |> String.trim()

  test "reviews the branch and returns a compact finding list", ctx do
    assert {:ok, text} = review(%{}, ctx.context)

    assert text =~ "Reviewed 1 file (changes since main): 1 blocking, 0 optional finding(s)."

    assert text =~
             "Blocking:\n1. lib/a.ex:3 [high, correctness] Guard against a missing key\n" <>
               "   Trigger: g/1 is called with a map without :key\n" <>
               "   map.key raises KeyError for such maps.\n" <>
               "   Suggestion:\n   def g(map), do: Map.get(map, :key)"

    refute text =~ "Optional:"
    refute text =~ "Notes:"
    assert_received {:llm_call, :detector}
    assert_received {:llm_call, :verifier}
  end

  # Regression: a confirmed finding the profile's threshold hides used to
  # vanish from the result, though the progress reported it as confirmed.
  test "lists verified findings the profile does not show, with the reason", ctx do
    profiles = %{
      "review-detector" => stage_spec("review-detector", ReportFindings),
      "review-verifier" => stage_spec("review-verifier", ReportVerdict, score: 0.3)
    }

    scope = start_scope(root: [allow_delegation: true], profiles: profiles)
    context = %{ctx.context | runtime: scope.root_agent_ref}

    assert {:ok, text} = review(%{}, context)
    assert text =~ "0 blocking, 0 optional finding(s)."

    assert text =~
             "Verified but not shown under the default profile:\n" <>
               "- lib/a.ex:3 [high, correctness] Guard against a missing key " <>
               "(confirmed, confidence 0.30 below the blocking threshold 0.50)\n" <>
               "   Trigger: g/1 is called with a map without :key"

    refute text =~ "Blocking:"

    # The assertive profile's threshold lets it through.
    assert {:ok, text} = review(%{"profile" => "assertive"}, context)
    assert text =~ "1 blocking, 0 optional finding(s)."
    refute text =~ "Verified but not shown"
  end

  test "keeps as many runs in flight as the agent may have children", ctx do
    {:ok, gauge} = Gauge.start_link()

    # Six files of 100 changed lines each are six batches: six detector runs.
    GitRepo.write(
      ctx.repo,
      Map.new(1..6, fn index ->
        body = Enum.map_join(1..100, fn line -> "  def f#{line}, do: #{index}\n" end)
        {"lib/f#{index}.ex", "defmodule F#{index} do\n" <> body <> "end\n"}
      end)
    )

    GitRepo.commit(ctx.repo, "six files")

    profiles = %{
      "review-detector" => stage_spec("review-detector", ReportFindings, gauge: {gauge, 3}),
      "review-verifier" => stage_spec("review-verifier", ReportVerdict)
    }

    scope =
      start_scope(
        root: [allow_delegation: true],
        profiles: profiles,
        limits: Limits.new!(max_children_per_agent: 3, max_agents_per_fleet: 16)
      )

    assert {:ok, _text} = review(%{}, %{ctx.context | runtime: scope.root_agent_ref})
    assert Gauge.peak(gauge) == 3
  end

  test "reports the review's progress as structured tool progress", ctx do
    test_pid = self()

    context =
      Map.merge(ctx.context, %{
        tool_call_id: "call-1",
        event_callback: &send(test_pid, {:progress, &1})
      })

    assert {:ok, _text} = review(%{"profile" => "quiet"}, context)

    reviews = collect_progress([])
    assert Enum.all?(reviews, &is_map/1)

    assert [
             %{
               kind: :loaded,
               target: "changes since main",
               files: 1,
               additions: 1,
               deletions: 0,
               profile: "quiet"
             },
             %{kind: :started, units: units} | _rest
           ] = reviews

    assert units > 0
    assert %{kind: :unit, status: :started} = Enum.find(reviews, &(&1.kind == :unit))
    assert Enum.any?(reviews, &match?(%{kind: :unit, unit: "lib/a.ex#1", status: :done}, &1))

    assert %{
             finding: %{
               fingerprint: fingerprint,
               title: "Guard against a missing key",
               severity: :high,
               category: :correctness,
               location: %{path: "lib/a.ex", side: :new, start_line: 3, end_line: 3}
             }
           } = Enum.find(reviews, &(&1.kind == :candidate))

    assert %{verdict: :confirmed} = Enum.find(reviews, &(&1[:fingerprint] == fingerprint))

    assert %{kind: :done, summary: %{files: 1, blocking: 1, optional: 0, candidates: 1}} =
             List.last(reviews)

    # The data is plain enough to forward as JSON.
    assert is_binary(JSON.encode!(reviews))
  end

  defp collect_progress(acc) do
    receive do
      {:progress, %Tackle.Lib.Event{type: :tool_progress, data: data}} ->
        assert %{tool_call_id: "call-1", name: "review_changes", review: review} = data
        collect_progress([review | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "uses the session's configured profile unless the model picks one", ctx do
    test_pid = self()

    context =
      Map.merge(ctx.context, %{
        tool_call_id: "call-1",
        event_callback: &send(test_pid, {:progress, &1}),
        review_settings: %Tackle.Review.Settings{profile: :assertive}
      })

    assert {:ok, _text} = review(%{}, context)
    assert [%{kind: :loaded, profile: "assertive"} | _rest] = collect_progress([])

    assert {:ok, _text} = review(%{"profile" => "quiet"}, context)
    assert [%{kind: :loaded, profile: "quiet"} | _rest] = collect_progress([])

    assert {:ok, _text} = review(%{}, Map.delete(context, :review_settings))
    assert [%{kind: :loaded, profile: "default"} | _rest] = collect_progress([])
  end

  test "records history in the repository's key and skips dismissed findings", ctx do
    assert {:ok, _text} = review(%{}, ctx.context)

    {:ok, history} = History.open(root(ctx.repo), home: ctx.home)
    assert File.dir?(history.dir)
    assert {:ok, [_run]} = History.runs(history)

    assert {:ok, [%{"event" => "shown", "fingerprint" => fingerprint}]} =
             History.finding_events(history)

    # A shown finding is reported again, so a review after a fix shows what is left.
    assert {:ok, again} = review(%{}, ctx.context)
    assert again =~ "Guard against a missing key"

    :ok = History.record_outcome(history, fingerprint, :dismissed)

    assert {:ok, text} = review(%{}, ctx.context)
    refute text =~ "Guard against a missing key"
    assert text =~ "0 blocking, 0 optional finding(s)."
    assert text =~ "Notes:\n- 1 dismissed finding not reported again."

    assert {:ok, [_, _, _]} = History.runs(history)
  end

  test "reviews staged changes and ranges, and history can be disabled", ctx do
    context = Map.put(ctx.context, :review_history, false)

    assert {:ok, text} = review(%{"staged" => true}, context)
    assert text == "Nothing to review in staged changes."

    GitRepo.commit(ctx.repo, "add g")

    assert {:ok, text} = review(%{"range" => "main..HEAD", "profile" => "quiet"}, context)
    assert text =~ "Guard against a missing key"
    assert text =~ "(main.."

    {:ok, history} = History.open(root(ctx.repo), home: ctx.home)
    refute File.exists?(history.dir)
  end

  test "an unavailable history is noted and the review still runs", ctx do
    blocked = Path.join(ctx.home, "file")
    File.write!(blocked, "")
    context = Map.put(ctx.context, :review_history, home: blocked)

    assert {:ok, text} = review(%{}, context)
    assert text =~ "Guard against a missing key"
    assert text =~ "review history could not be written"

    assert {:ok, text} = review(%{}, Map.put(ctx.context, :review_history, :bogus))
    assert text =~ "Review history is misconfigured: :bogus"
  end

  test "reports invalid input and change errors to the model", ctx do
    assert {:error, message} = review(%{"profile" => "loud"}, ctx.context)
    assert message =~ "invalid input"

    assert {:error, message} = review(%{"range" => "no-such-ref..HEAD"}, ctx.context)
    assert message == "Cannot load the change: unknown revision: no-such-ref"

    assert {:error, message} =
             review(%{"range" => "main..HEAD", "staged" => true}, ctx.context)

    assert message =~ "Cannot load the change:"

    outside = tmp_home()
    assert {:error, message} = review(%{}, Map.put(ctx.context, :cwd, outside))
    assert message =~ "is not inside a Git repository"

    refute_received {:llm_call, _stage}
  end

  test "a jailed agent only reviews a repository inside its workspace", ctx do
    workspace = Path.join(ctx.repo, "nested")
    File.mkdir_p!(workspace)
    # Loading never talks to the exec-server, so any client will do.
    jailed = Jailed.new(self(), workspace: workspace)
    context = %{ctx.context | cwd: workspace} |> Map.put(:executor, jailed)

    # As for `git` in the jail, the repository around the workspace is not
    # visible.
    assert {:error, message} = review(%{}, context)
    assert message == "Cannot load the change: #{workspace} is not inside a Git repository"
    refute_received {:llm_call, _stage}
  end

  test "requires a runtime reference to an agent that may delegate", ctx do
    assert {:error, message} = review(%{}, Map.delete(ctx.context, :runtime))
    assert message =~ "no runtime reference"

    no_delegation = start_scope(root: [allow_delegation: false], profiles: %{})

    assert {:error, message} =
             review(%{}, %{ctx.context | runtime: no_delegation.root_agent_ref})

    assert message =~ "delegation"
    refute_received {:llm_call, _stage}
  end

  test "a coding scope's root agent reviews its changes through the loop", ctx do
    {:ok, spec} =
      Tackle.Coding.scope_spec(
        root_tools: [Tackle.Tools.Review],
        available_adapters: [Adapter],
        cwd: ctx.repo,
        env: %{"TACKLE_HOME" => ctx.home},
        overrides: [
          model: "tool-review/fake",
          llm_opts: [test_pid: self()],
          retry: false,
          context: %{review_history: [home: ctx.home]}
        ]
      )

    {:ok, scope} = Tackle.Runtime.start_scope(spec)
    on_exit(fn -> Tackle.Test.Runtime.stop_scope(scope.scope_ref) end)

    {:ok, session} = Tackle.Runtime.session_pid(scope.root_agent_ref)
    {:ok, %{session_id: session_id}} = Tackle.Session.subscribe(session)
    assert {:ok, turn_id} = Tackle.Runtime.submit(scope.root_agent_ref, "check your work")
    assert_receive {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, state}}, 10_000

    assert %{content: content} = Enum.find(state.messages, &(&1.role == :tool))
    assert content =~ "1. lib/a.ex:3 [high, correctness] Guard against a missing key"

    {:ok, history} = History.open(root(ctx.repo), home: ctx.home)
    assert {:ok, [_run]} = History.runs(history)
  end

  test "fails clearly when the scope lacks the review profiles", ctx do
    scope = start_scope(root: [allow_delegation: true], profiles: %{})

    assert {:error, message} = review(%{}, %{ctx.context | runtime: scope.root_agent_ref})

    assert message ==
             "The review failed: the review-detector agent profile is not available in this session"

    refute_received {:llm_call, _stage}
  end
end
