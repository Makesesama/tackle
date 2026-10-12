defmodule Tackle.CLI.ReviewTest do
  # Changes the working directory and application environment.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import ExUnit.CaptureIO

  alias Tackle.CLI.Review

  defmodule Adapter do
    @moduledoc false
    # Scripted provider for the review stages; no network, no credentials.
    # The detector reports one finding for lib/a.ex, the verifier confirms
    # it, and the scorer answers 0.9.

    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "cli-review"

    @impl true
    def models, do: ["fake"]

    @impl true
    def model_info(_model), do: %{context_window: 100_000, max_output_tokens: 1_000}

    @impl true
    def generate(schema, opts) do
      messages = Keyword.get(opts, :messages, [])
      system = Keyword.get(opts, :system, "")
      answered? = Enum.any?(messages, &(&1.role == :tool))
      prompt = Enum.find_value(messages, "", &(&1.role == :user && &1.content))
      stage = stage(schema, system)
      send(Application.fetch_env!(:tackle_cli, :review_test_pid), {:review_llm, stage})

      data =
        case {stage, answered?} do
          {:scorer, _answered?} -> %{"confidence" => 0.9}
          {_stage, true} -> %{"content" => "Done.", "tool_calls" => []}
          {:detector, false} -> report(prompt)
          {:verifier, false} -> verdict()
          {:root, false} -> %{"content" => "unused", "tool_calls" => []}
        end

      {:ok, %{data: data, usage: %{input_tokens: 10, output_tokens: 5}, model: "fake"}}
    end

    defp stage(schema, _system) when schema != nil, do: :scorer

    defp stage(nil, system) do
      cond do
        system =~ "## Review detector assignment" -> :detector
        system =~ "## Review verifier assignment" -> :verifier
        true -> :root
      end
    end

    defp report(prompt) do
      findings =
        if prompt =~ ~s(<unit id="lib/a.ex#1">) do
          [
            %{
              "title" => "Guard against a missing key",
              "category" => "correctness",
              "severity" => "high",
              "blocking" => Application.get_env(:tackle_cli, :review_test_blocking, true),
              "confidence" => 0.8,
              "rule_id" => "missing-nil-check",
              "location" => %{
                "path" => "lib/a.ex",
                "side" => "new",
                "start_line" => 3,
                "end_line" => 3
              },
              "trigger" => "g/1 is called with a map without :key",
              "body" => "map.key raises KeyError for such maps.",
              "suggestion" => nil
            }
          ]
        else
          []
        end

      tool_call("report_findings", %{"findings" => findings})
    end

    defp verdict do
      tool_call("report_verdict", %{
        "verdict" => "confirmed",
        "evidence" => "lib/a.ex:3 reads map.key without a check."
      })
    end

    defp tool_call(name, arguments) do
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

  @git_env [
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_NOSYSTEM", "1"},
    {"GIT_AUTHOR_NAME", "Review"},
    {"GIT_AUTHOR_EMAIL", "review@example.com"},
    {"GIT_COMMITTER_NAME", "Review"},
    {"GIT_COMMITTER_EMAIL", "review@example.com"}
  ]

  setup do
    base = Path.join(System.tmp_dir!(), "tackle-cli-review-#{System.unique_integer([:positive])}")
    home = Path.join(base, "home")
    repo = Path.join(base, "repo")
    File.mkdir_p!(home)
    File.mkdir_p!(repo)

    previous_home = System.get_env("TACKLE_HOME")
    previous_adapters = Application.get_env(:tackle, :adapters)
    System.put_env("TACKLE_HOME", home)
    Application.put_env(:tackle, :adapters, [Adapter])
    Application.put_env(:tackle_cli, :review_test_pid, self())

    on_exit(fn ->
      restore_env("TACKLE_HOME", previous_home)
      restore_app_env(:tackle, :adapters, previous_adapters)
      Application.delete_env(:tackle_cli, :review_test_pid)
      Application.delete_env(:tackle_cli, :review_test_blocking)
      File.rm_rf!(base)
    end)

    git(repo, ["init", "-q", "-b", "main"])
    write(repo, "lib/a.ex", "defmodule A do\n  def f(x), do: x\nend\n")
    git(repo, ["add", "-A"])
    git(repo, ["commit", "-q", "--no-verify", "-m", "initial"])
    git(repo, ["checkout", "-q", "-b", "feature"])

    {:ok, repo: repo, base: base, home: home}
  end

  defp opts(overrides \\ %{}) do
    Map.merge(
      %{
        model: "cli-review/fake",
        thinking: nil,
        range: nil,
        staged: false,
        profile: :default,
        samples: 1,
        format: :text
      },
      overrides
    )
  end

  # Runs the command in `dir` and returns {status, stdout, stderr}.
  defp review(dir, opts) do
    stderr =
      capture_io(:stderr, fn ->
        stdout =
          capture_io(fn -> send(self(), {:status, File.cd!(dir, fn -> Review.run(opts) end)}) end)

        send(self(), {:stdout, stdout})
      end)

    assert_received {:status, status}
    assert_received {:stdout, stdout}
    {status, stdout, stderr}
  end

  defp add_unguarded_access(repo) do
    write(repo, "lib/a.ex", "defmodule A do\n  def f(x), do: x\n  def g(map), do: map.key\nend\n")
  end

  test "reviews the branch with uncommitted changes and exits 1 on a blocking finding", %{
    repo: repo
  } do
    add_unguarded_access(repo)

    {status, stdout, stderr} = review(repo, opts())

    assert status == 1
    assert stdout =~ "Blocking (1)"
    assert stdout =~ "HIGH    lib/a.ex:3  Guard against a missing key"
    assert stdout =~ "Trigger: g/1 is called with a map without :key"
    assert stdout =~ "Rule: missing-nil-check"
    assert stdout =~ "Blocking findings found."
    assert stdout =~ "changes since main"

    assert stderr =~ "Reviewing 2 units…"
    assert stderr =~ "Reviewed lib/a.ex#1"
    assert stderr =~ "Verifying lib/a.ex:3 Guard against a missing key"
    assert stderr =~ "Confirmed: lib/a.ex:3 Guard against a missing key"
    refute stdout =~ "Reviewing"

    assert_received {:review_llm, :detector}
    assert_received {:review_llm, :verifier}
    assert_received {:review_llm, :scorer}
    refute_received {:review_llm, :root}
  end

  test "prints the JSON result for a range and exits 0 without blocking findings", %{repo: repo} do
    Application.put_env(:tackle_cli, :review_test_blocking, false)
    add_unguarded_access(repo)
    git(repo, ["commit", "-q", "-a", "--no-verify", "-m", "add g"])

    {status, stdout, stderr} =
      review(repo, opts(%{range: "main..HEAD", format: :json, profile: :assertive}))

    assert status == 0
    assert stderr =~ "Reviewing 2 units…"

    json = JSON.decode!(stdout)
    assert json["verdict"] == "optional"
    assert json["blocking"] == []

    assert [%{"title" => "Guard against a missing key", "verdict" => "confirmed"} = finding] =
             json["optional"]

    assert finding["location"] == %{
             "path" => "lib/a.ex",
             "side" => "new",
             "start_line" => 3,
             "end_line" => 3
           }

    assert finding["confidence"] == 0.9
    assert json["change"]["mode"] == "range"
    assert json["change"]["base_ref"] == "main"
    assert json["summary"]["profile"] == "assertive"
    assert json["summary"]["files"] == ["lib/a.ex"]
    assert json["usage"]["input_tokens"] > 0
  end

  test "records history and does not report dismissed findings again", %{repo: repo, home: home} do
    add_unguarded_access(repo)

    {status, _stdout, _stderr} = review(repo, opts())
    assert status == 1

    root = repo |> git(["rev-parse", "--show-toplevel"]) |> String.trim()
    {:ok, history} = Tackle.Review.History.open(root, home: home)
    assert history.dir == Path.join([home, "review", Tackle.Paths.project_key(root)])
    assert {:ok, [run]} = Tackle.Review.History.runs(history)
    assert run["summary"]["blocking"] == 1

    assert {:ok, [%{"event" => "shown", "fingerprint" => fingerprint}]} =
             Tackle.Review.History.finding_events(history)

    # A finding shown before is reported again; the exit status does not change.
    assert {1, _stdout, _stderr} = review(Path.join(repo, "lib"), opts())

    :ok = Tackle.Review.History.record_outcome(history, fingerprint, :dismissed)

    {status, stdout, _stderr} = review(repo, opts(%{format: :json}))
    assert status == 0
    json = JSON.decode!(stdout)
    assert json["blocking"] == []
    assert [%{"reason" => "known"}] = json["dropped"]
    assert {:ok, runs} = Tackle.Review.History.runs(history)
    assert length(runs) == 3
  end

  test "an empty change needs no model and exits 0", %{repo: repo} do
    {status, stdout, stderr} = review(repo, opts(%{staged: true}))

    assert status == 0
    assert stdout =~ "No findings."
    assert stdout =~ "Nothing to review in staged changes"
    assert stderr == ""
    refute_received {:review_llm, _stage}
  end

  test "exits 2 with a message when the change cannot be loaded", %{repo: repo, base: base} do
    {status, stdout, stderr} = review(repo, opts(%{range: "no-such-ref..HEAD"}))

    assert status == 2
    assert stdout == ""
    assert stderr =~ "error: unknown revision: no-such-ref"

    outside = Path.join(base, "not-a-repo")
    File.mkdir_p!(outside)

    {status, _stdout, stderr} = review(outside, opts(%{format: :json}))
    assert status == 2
    assert %{"error" => message} = JSON.decode!(stderr)
    assert message =~ "is not inside a Git repository"
  end

  test "exits 2 when the scope cannot start", %{repo: repo} do
    {status, stdout, stderr} = review(repo, opts(%{model: "cli-review/missing"}))

    assert status == 2
    assert stdout == ""
    assert stderr =~ "error:"
    assert stderr =~ "cli-review/missing"
    refute_received {:review_llm, _stage}
  end

  defp write(repo, path, contents) do
    full = Path.join(repo, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, contents)
  end

  defp git(dir, args) do
    case System.cmd("git", args, cd: dir, env: @git_env, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> raise "git #{Enum.join(args, " ")} failed (#{status}): #{output}"
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)
end
