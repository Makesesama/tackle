defmodule Tackle.Tools.ReviewTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import Tackle.Test.Runtime, only: [start_scope: 1, handle: 1, handle: 2, tmp_home: 0]

  alias Tackle.Config
  alias Tackle.Executor.Jailed
  alias Tackle.Lib.Tool
  alias Tackle.Review.History
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Test.GitRepo
  alias Tackle.Tools.{ReportFindings, ReportVerdict}

  defmodule Adapter do
    @moduledoc false
    # Scripted review stages: the detector reports one finding for lib/a.ex,
    # the verifier confirms it, and the scorer answers 0.9. A root agent
    # calls review_changes once and then answers.

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

      {:ok,
       %{
         data: data(stage, answered?, prompt),
         usage: %{input_tokens: 10, output_tokens: 5},
         model: "fake"
       }}
    end

    defp stage(schema, _prompt) when schema != nil, do: :scorer
    defp stage(nil, "Verify" <> _rest), do: :verifier
    defp stage(nil, prompt), do: if(prompt =~ "<unit id=", do: :detector, else: :root)

    defp data(:scorer, _answered?, _prompt),
      do: %{"scores" => [%{"id" => "C1", "confidence" => 0.9}]}

    defp data(_stage, true, _prompt), do: %{"content" => "Done.", "tool_calls" => []}

    defp data(:detector, false, prompt),
      do: call("report_findings", %{"findings" => findings(prompt)})

    defp data(:verifier, false, _prompt), do: call("report_verdict", verdict())
    defp data(:root, false, _prompt), do: call("review_changes", %{})

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

    context = %{runtime: handle(scope), cwd: repo, review_history: [home: home]}
    {:ok, repo: repo, scope: scope, home: home, context: context}
  end

  defp stage_spec(name, tool) do
    {:ok, config} =
      Config.new(
        adapters: [Adapter],
        model: "tool-review/fake",
        tools: [tool],
        system_prompt: "Review stage.",
        max_iterations: 6,
        llm_opts: [test_pid: self()]
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

  test "requires a runtime handle that may delegate", ctx do
    assert {:error, message} = review(%{}, Map.delete(ctx.context, :runtime))
    assert message =~ "no runtime handle"

    no_delegation = handle(ctx.scope, allow_delegation: false)

    assert {:error, message} = review(%{}, %{ctx.context | runtime: no_delegation})
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

    assert {:error, message} = review(%{}, %{ctx.context | runtime: handle(scope)})

    assert message ==
             "The review failed: the review-detector agent profile is not available in this session"

    refute_received {:llm_call, _stage}
  end
end
