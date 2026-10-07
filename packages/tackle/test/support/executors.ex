defmodule Tackle.Test.Executors do
  @moduledoc false
  # Runs tool tests against every executor. Use with
  #
  #     use ExUnit.Case, async: true, parameterize: Tackle.Test.Executors.parameters()
  #     setup :start_executor
  #
  # The jailed executor runs the real exec-server in a plain `erl`, without a
  # jail, so paths are the same as on the host.

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias Tackle.Exec.Client
  alias Tackle.Executor
  alias Tackle.Executor.Jailed

  def parameters, do: [%{executor_kind: :local}, %{executor_kind: :jailed}]

  def start_executor(%{executor_kind: :local}), do: %{executor: Executor.local()}

  def start_executor(%{executor_kind: :jailed}) do
    client = start_supervised!({Client, launcher: launcher()})
    %{executor: Jailed.new(client, workspace: "/", tmp_dir: System.tmp_dir!())}
  end

  # Keep the exec-server's standard error away from the test output, as a
  # production launcher would.
  defp launcher do
    sh = System.find_executable("sh") || raise "sh was not found on PATH"
    erl = System.find_executable("erl") || raise "erl was not found on PATH"
    elixir_ebin = Path.join(:code.lib_dir(:elixir), "ebin")
    ebin = :tackle_exec |> :code.lib_dir() |> Path.join("ebin")
    log = Path.join(System.tmp_dir!(), "tackle_executor_test_stderr.log")
    script = ~S(log=$1; shift; exec "$@" 2>>"$log")

    {sh,
     ["-c", script, "sh", log, erl, "-noshell", "-noinput", "-pa", elixir_ebin, "-pa", ebin] ++
       ["-s", "Elixir.Tackle.Exec.Server", "main"]}
  end
end
