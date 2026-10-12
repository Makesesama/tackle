defmodule Tackle.Review.GitTest do
  alias Tackle.Test.Executors

  # The output and time bounds guard against a hostile executor, so every case
  # runs under the local and the jailed executor.
  use ExUnit.Case, async: true, parameterize: Executors.parameters()

  import Executors, only: [start_executor: 1]

  alias Tackle.Review.Git
  alias Tackle.Test.GitRepo

  defmodule Recording do
    @moduledoc false
    # Wraps an executor and reports commands and deletions to the test.

    @behaviour Tackle.Executor

    alias Tackle.Executor

    def new(inner, pid), do: {__MODULE__, {inner, pid}}

    @impl true
    def exec({inner, pid}, argv, opts) do
      send(pid, {:exec, argv, opts})
      Executor.exec(inner, argv, opts)
    end

    @impl true
    def await({inner, _pid}, handle, timeout), do: Executor.await(inner, handle, timeout)

    @impl true
    def cancel({inner, pid}, handle) do
      send(pid, :cancel)
      Executor.cancel(inner, handle)
    end

    @impl true
    def read({inner, _pid}, path, offset, length), do: Executor.read(inner, path, offset, length)

    @impl true
    def write({inner, _pid}, path, data, opts), do: Executor.write(inner, path, data, opts)

    @impl true
    def delete({inner, pid}, path) do
      result = Executor.delete(inner, path)
      send(pid, {:delete, path, result})
      result
    end

    @impl true
    def stat({inner, _pid}, path), do: Executor.stat(inner, path)

    @impl true
    def list({inner, _pid}, path), do: Executor.list(inner, path)

    @impl true
    def tmp_dir({inner, _pid}), do: Executor.tmp_dir(inner)

    @impl true
    def workspace({inner, _pid}), do: Executor.workspace(inner)
  end

  setup :start_executor

  setup %{executor: executor} do
    dir = GitRepo.init()
    GitRepo.write(dir, %{"a.txt" => "one\ntwo\nthree\n"})
    GitRepo.commit(dir, "base")
    GitRepo.write(dir, %{"a.txt" => "one\nTWO\nthree\n"})
    %{dir: dir, recording: Recording.new(executor, self())}
  end

  # The temporary file `diff/3` passed to `git diff --output`.
  defp output_file do
    assert_received {:exec, ["git" | args], _opts}
    assert [file] = for("--output=" <> file <- args, do: file)
    file
  end

  describe "run/3" do
    test "returns the output of a successful command", %{dir: dir, executor: executor} do
      assert Git.run(dir, ["rev-parse", "--show-toplevel"], executor: executor) ==
               {:ok, dir <> "\n"}
    end

    test "runs Git untranslated in the C locale", %{dir: dir, recording: recording} do
      assert {:ok, _output} = Git.run(dir, ["rev-parse", "HEAD"], executor: recording)
      assert_received {:exec, _argv, opts}
      env = Keyword.fetch!(opts, :env)
      assert {"LC_ALL", "C"} in env
      assert {"LANGUAGE", "C"} in env
    end

    test "a non-zero exit status is a Git failure", %{dir: dir, executor: executor} do
      assert {:error, {:git_failed, 128, output}} =
               Git.run(dir, ["rev-parse", "--verify", "no-such-ref"], executor: executor)

      assert output =~ "fatal"
    end

    test "cancels a command whose output exceeds max_bytes",
         %{dir: dir, recording: recording} do
      assert Git.run(dir, ["cat-file", "-p", "HEAD"], executor: recording, max_bytes: 10) ==
               {:error, :too_large}

      assert_received :cancel
    end

    test "output up to max_bytes is accepted", %{dir: dir, executor: executor} do
      {:ok, output} = Git.run(dir, ["rev-parse", "HEAD"], executor: executor)

      assert Git.run(dir, ["rev-parse", "HEAD"], executor: executor, max_bytes: byte_size(output)) ==
               {:ok, output}
    end

    test "cancels a command that does not finish in time", %{dir: dir, recording: recording} do
      # A shell alias keeps Git running well past the deadline; cancelling
      # kills the whole process group, including `sleep`.
      started = System.monotonic_time(:millisecond)

      assert Git.run(dir, ["-c", "alias.slow=!sleep 30", "slow"],
               executor: recording,
               timeout: 100
             ) == {:error, :timeout}

      assert System.monotonic_time(:millisecond) - started < 10_000
      assert_received :cancel
    end
  end

  describe "diff/3" do
    test "returns the patch and removes the temporary file", %{dir: dir, recording: recording} do
      assert {:ok, patch} = Git.diff(dir, [], executor: recording)
      assert patch =~ "+TWO"

      file = output_file()
      assert_received {:delete, ^file, :ok}
      refute File.exists?(file)
    end

    test "a patch larger than max_bytes is too large and still removed",
         %{dir: dir, recording: recording} do
      # `git diff --output` prints nothing, so the bound applies to the file.
      assert Git.diff(dir, [], executor: recording, max_bytes: 10) == {:error, :too_large}

      file = output_file()
      refute_received :cancel
      assert_received {:delete, ^file, :ok}
      refute File.exists?(file)
    end

    test "removes the temporary file when Git fails after writing it",
         %{dir: dir, recording: recording} do
      # With --exit-code, Git writes the patch and then exits with status 1.
      assert Git.diff(dir, ["--exit-code"], executor: recording) == {:error, {:git_failed, 1, ""}}

      file = output_file()
      assert_received {:delete, ^file, :ok}
      refute File.exists?(file)
    end

    test "removes the temporary file when Git rejects a revision",
         %{dir: dir, recording: recording} do
      assert {:error, {:git_failed, 128, _output}} =
               Git.diff(dir, ["--end-of-options", "no-such-ref"], executor: recording)

      file = output_file()
      assert_received {:delete, ^file, _result}
      refute File.exists?(file)
    end

    test "a diff that does not finish in time is cancelled and removed",
         %{dir: dir, recording: recording} do
      # `diff/3` takes no Git options, so slow the diff down with an external
      # diff driver from the repository configuration.
      GitRepo.git(dir, ["config", "diff.external", "sleep 30 #"])

      assert Git.diff(dir, ["--ext-diff"], executor: recording, timeout: 100) ==
               {:error, :timeout}

      file = output_file()
      assert_received :cancel
      assert_received {:delete, ^file, _result}
      refute File.exists?(file)
    end
  end

  test "formats errors" do
    assert Git.format_error({:git_failed, 1, ""}) == "git exited with status 1"

    assert Git.format_error({:git_failed, 128, "fatal: x\n"}) ==
             "git exited with status 128: fatal: x"

    assert Git.format_error(:timeout) == "git did not finish in time"
    assert Git.format_error(:too_large) == "git output is too large"
  end
end
