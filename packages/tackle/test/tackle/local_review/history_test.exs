defmodule Tackle.LocalReview.HistoryTest do
  use ExUnit.Case, async: true

  import Tackle.Test.Runtime, only: [tmp_home: 0]

  alias Tackle.Lib.Usage
  alias Tackle.LocalReview.History
  alias Tackle.Review.{Change, Diff, Finding, Result}
  alias Tackle.Session.Storage

  setup do
    home = tmp_home()
    {:ok, history} = History.open("/home/dev/projects/my-app", home: home)
    {:ok, home: home, history: history}
  end

  defp finding(title, overrides \\ %{}) do
    input =
      Map.merge(
        %{
          "title" => title,
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
          "body" => "map.key raises KeyError.",
          "suggestion" => nil
        },
        overrides
      )

    {:ok, finding} = Finding.from_input(input)
    %{Finding.put_fingerprint(finding, "map.key") | verdict: :confirmed}
  end

  defp change do
    {:ok, diff} = Diff.parse("")

    %Change{
      cwd: "/home/dev/projects/my-app/lib",
      root: "/home/dev/projects/my-app",
      mode: :range,
      base_ref: "main",
      base_sha: String.duplicate("a", 40),
      head_sha: String.duplicate("b", 40),
      diff: diff
    }
  end

  defp result(blocking, optional, rejected) do
    %Result{
      blocking: blocking,
      optional: optional,
      rejected: Enum.map(rejected, &%{finding: &1, evidence: "Handled by the caller."}),
      summary: %{
        profile: :default,
        samples: 1,
        units: 2,
        files: ["lib/a.ex"],
        skipped: [],
        failed_units: [],
        incomplete_units: [],
        detected: 3,
        candidates: 3,
        confirmed: length(blocking ++ optional),
        uncertain: 0,
        rejected: length(rejected),
        verification_failures: [],
        scoring_failures: [],
        blocking: length(blocking),
        optional: length(optional),
        verdict: Result.verdict(blocking, optional),
        warnings: []
      },
      usage: %Usage{input_tokens: 100, output_tokens: 20, total_tokens: 120}
    }
  end

  defp mode(path) do
    {:ok, %{mode: mode}} = File.stat(path)
    Bitwise.band(mode, 0o777)
  end

  test "keys the history by repository root, encoded like session project directories", ctx do
    root = "/home/dev/projects/my-app"
    assert ctx.history.root == root
    assert ctx.history.project_key == "--home-dev-projects-my-2Dapp--"
    assert ctx.history.dir == Path.join([ctx.home, "review", "--home-dev-projects-my-2Dapp--"])

    for path <- [root, "/tmp/a-b", "/tmp/a/b", "/tmp/with space/-dash-", "/"] do
      {:ok, session_dir} = Storage.session_dir("session-1", home: ctx.home, cwd: path)
      {:ok, history} = History.open(path, home: ctx.home)
      assert history.project_key == session_dir |> Path.dirname() |> Path.basename()
    end

    # Relative roots are expanded like session working directories.
    {:ok, relative} = History.open(".", home: ctx.home)
    assert relative.root == File.cwd!()
  end

  test "resolves the home from TACKLE_HOME and rejects invalid input", ctx do
    assert {:ok, history} = History.open("/repo", env: %{"TACKLE_HOME" => ctx.home})
    assert String.starts_with?(history.dir, Path.join(ctx.home, "review"))

    assert {:error, :user_home_unavailable} = History.open("/repo", env: %{}, user_home: nil)
    assert {:error, {:invalid_home, 1}} = History.open("/repo", home: 1)
    assert {:error, {:invalid_root, ""}} = History.open("")
    assert {:error, {:invalid_root, nil}} = History.open(nil)
  end

  test "opening does not touch the file system", ctx do
    refute File.exists?(ctx.history.dir)
    assert {:ok, []} = History.runs(ctx.history)
    assert {:ok, []} = History.finding_events(ctx.history)
    assert {:ok, fingerprints} = History.fingerprints(ctx.history, [:dismissed])
    assert MapSet.size(fingerprints) == 0
    refute File.exists?(ctx.history.dir)
  end

  test "records a run with its shown and rejected findings and reads it back", ctx do
    shown = finding("Guard against a missing key")
    optional = finding("Rename f", %{"blocking" => false, "severity" => "low"})
    rejected = finding("Check the list for emptiness")

    result =
      update_in(
        result([shown], [optional], [rejected]).summary,
        &Map.merge(&1, %{
          rules: [
            %{id: "missing-nil-check", source: :project, status: :active, digest: "0123abcd"}
          ],
          prompts: %{"review-detector" => "aaaa1111", "review-verifier" => "bbbb2222"}
        })
      )

    assert {:ok, run_id} = History.record_run(ctx.history, change(), result)

    assert {:ok, [run]} = History.runs(ctx.history)
    assert run["id"] == run_id
    assert run["version"] == 1
    assert {:ok, _at, 0} = DateTime.from_iso8601(run["at"])
    assert run["root"] == "/home/dev/projects/my-app"

    assert run["change"] == %{
             "mode" => "range",
             "base_ref" => "main",
             "base_sha" => String.duplicate("a", 40),
             "head_sha" => String.duplicate("b", 40)
           }

    assert run["profile"] == "default"
    assert run["samples"] == 1

    assert %{"blocking" => 1, "optional" => 1, "rejected" => 1, "verdict" => "blocking"} =
             run["summary"]

    assert run["rules"] == [
             %{
               "id" => "missing-nil-check",
               "source" => "project",
               "status" => "active",
               "digest" => "0123abcd"
             }
           ]

    assert run["prompts"] == %{"review-detector" => "aaaa1111", "review-verifier" => "bbbb2222"}
    assert run["usage"] == %{"input_tokens" => 100, "output_tokens" => 20, "total_tokens" => 120}

    assert {:ok, [first, second, third]} = History.finding_events(ctx.history)
    assert %{"event" => "shown", "run_id" => ^run_id} = first
    assert first["fingerprint"] == shown.fingerprint

    assert first["finding"] == %{
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
             "body" => "map.key raises KeyError.",
             "suggestion" => nil,
             "support" => 1,
             "verdict" => "confirmed"
           }

    assert %{"event" => "shown", "fingerprint" => fp} = second
    assert fp == optional.fingerprint

    assert %{"event" => "rejected", "evidence" => "Handled by the caller."} = third
    assert third["fingerprint"] == rejected.fingerprint

    assert {:ok, shown_fps} = History.fingerprints(ctx.history, [:shown])
    assert shown_fps == MapSet.new([shown.fingerprint, optional.fingerprint])
  end

  test "a result without digests records no rules or prompts", ctx do
    {:ok, _} = History.record_run(ctx.history, change(), result([], [], []))
    {:ok, [run]} = History.runs(ctx.history)
    assert run["rules"] == []
    assert run["prompts"] == %{}
    # A run without findings writes no finding events.
    assert {:ok, []} = History.finding_events(ctx.history)
  end

  test "creates private directories and files", ctx do
    {:ok, _run_id} = History.record_run(ctx.history, change(), result([finding("A")], [], []))

    assert mode(Path.join(ctx.home, "review")) == 0o700
    assert mode(ctx.history.dir) == 0o700
    assert mode(History.runs_path(ctx.history)) == 0o600
    assert mode(History.findings_path(ctx.history)) == 0o600

    # Existing files with looser permissions are restricted on the next write.
    File.chmod!(History.findings_path(ctx.history), 0o644)
    :ok = History.record_outcome(ctx.history, finding("A").fingerprint, :useful)
    assert mode(History.findings_path(ctx.history)) == 0o600
  end

  test "records outcomes and reads fingerprints by event", ctx do
    a = finding("A").fingerprint
    b = finding("B").fingerprint

    assert :ok =
             History.record_outcome(ctx.history, a, :dismissed, note: "intended", run_id: "r1")

    assert :ok = History.record_outcome(ctx.history, b, :useful)
    assert :ok = History.record_outcome(ctx.history, b, :fixed)

    assert {:ok, [dismissed, useful, fixed]} = History.finding_events(ctx.history)

    assert %{"event" => "dismissed", "fingerprint" => ^a, "note" => "intended", "run_id" => "r1"} =
             dismissed

    assert %{"event" => "useful", "fingerprint" => ^b, "run_id" => nil} = useful
    refute Map.has_key?(useful, "note")
    assert %{"event" => "fixed"} = fixed

    assert {:ok, fps} = History.fingerprints(ctx.history, [:dismissed])
    assert fps == MapSet.new([a])
    assert {:ok, fps} = History.fingerprints(ctx.history, [:dismissed, :fixed])
    assert fps == MapSet.new([a, b])
    assert {:ok, fps} = History.fingerprints(ctx.history, [])
    assert MapSet.size(fps) == 0
  end

  test "rejects invalid outcomes, fingerprints, and events", ctx do
    assert {:error, {:invalid_outcome, :shown}} =
             History.record_outcome(ctx.history, "abc", :shown)

    assert {:error, {:invalid_outcome, :great}} =
             History.record_outcome(ctx.history, "abc", :great)

    assert {:error, {:invalid_fingerprint, ""}} =
             History.record_outcome(ctx.history, "", :useful)

    assert {:error, {:invalid_events, [:great]}} =
             History.fingerprints(ctx.history, [:dismissed, :great])

    refute File.exists?(ctx.history.dir)
    assert History.outcomes() == [:useful, :not_useful, :dismissed, :fixed]
    assert History.events() -- History.outcomes() == [:shown, :rejected]
  end

  test "skips lines that cannot be decoded or are not events", ctx do
    :ok = History.record_outcome(ctx.history, "aaa", :dismissed)
    path = History.findings_path(ctx.history)

    File.write!(
      path,
      [
        "not json\n",
        ~s({"event":"bogus","fingerprint":"ccc"}\n),
        ~s({"event":"dismissed"}\n),
        ~s([1, 2]\n)
      ],
      [:append]
    )

    :ok = History.record_outcome(ctx.history, "bbb", :dismissed)
    # A partial last line, as a crash in the middle of a write could leave.
    File.write!(path, ~s({"event":"dismissed","finger), [:append])

    assert {:ok, events} = History.finding_events(ctx.history)
    assert Enum.map(events, & &1["fingerprint"]) == ["aaa", "bbb"]
    assert {:ok, fps} = History.fingerprints(ctx.history, [:dismissed])
    assert fps == MapSet.new(["aaa", "bbb"])
  end

  test "reports write and read failures", ctx do
    # The Tackle home is a regular file, so the review directory cannot exist.
    blocked = Path.join(ctx.home, "blocked")
    File.write!(blocked, "")
    {:ok, history} = History.open("/repo", home: blocked)

    assert {:error, {:mkdir_failed, _path, _reason} = reason} =
             History.record_outcome(history, "aaa", :dismissed)

    assert History.format_error(reason) =~ "cannot create"

    assert {:error, {:mkdir_failed, _path, _reason}} =
             History.record_run(history, change(), result([finding("A")], [], []))

    # A directory where the log should be cannot be read.
    File.mkdir_p!(History.findings_path(ctx.history))

    assert {:error, {:read_failed, _path, :eisdir} = reason} =
             History.fingerprints(ctx.history, [:dismissed])

    assert History.format_error(reason) =~ "cannot read"
  end
end
