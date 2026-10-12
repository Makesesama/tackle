defmodule Tackle.Review.Git do
  @moduledoc """
  Runs read-only Git commands for code review through a `Tackle.Executor`.

  Commands run through the executor, so a review works the same under
  `Tackle.Executor.Jailed`. The executor merges standard error into standard
  output, so diffs are written to a temporary file with `git diff --output`
  and read back; warnings Git prints while diffing cannot end up in the
  patch. Output is bounded because the executor may be hostile.

  Optional index locks are disabled (`GIT_OPTIONAL_LOCKS=0`), so a review does
  not contend with a concurrent `git` command in the same repository. Git runs
  in the `C` locale (`LC_ALL=C`, `LANGUAGE=C`), so its messages are untranslated
  and errors such as "not a git repository" can be recognised.
  """

  alias Tackle.Executor

  @default_timeout 60_000
  @default_max_bytes 32 * 1_024 * 1_024
  @poll_interval 50

  @env [
    {"GIT_OPTIONAL_LOCKS", "0"},
    {"GIT_TERMINAL_PROMPT", "0"},
    {"GIT_PAGER", "cat"},
    {"LC_ALL", "C"},
    {"LANGUAGE", "C"}
  ]

  @typedoc """
  Command options: `:executor` (default local), `:timeout` in milliseconds
  (default 60 s) and `:max_bytes` of output (default 32 MiB).
  """
  @type option ::
          {:executor, Executor.t()}
          | {:timeout, pos_integer()}
          | {:max_bytes, pos_integer()}

  @typedoc "Why a command failed."
  @type error ::
          {:git_failed, non_neg_integer(), String.t()}
          | :timeout
          | :too_large
          | Executor.reason()

  @doc """
  Runs `git args` in `cwd` and returns its output.

  A non-zero exit status returns `{:error, {:git_failed, status, output}}`.
  """
  @spec run(Path.t(), [String.t()], [option()]) :: {:ok, binary()} | {:error, error()}
  def run(cwd, args, opts \\ []) do
    executor = Keyword.get(opts, :executor) || Executor.local()
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, @default_timeout)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    argv = ["git", "-c", "core.quotePath=false", "-c", "color.ui=false" | args]

    case Executor.exec(executor, argv, cwd: cwd, env: @env) do
      {:ok, handle} -> collect(executor, handle, deadline, max_bytes, {[], 0})
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Runs `git diff args` in `cwd` and returns the patch text.

  The patch goes through a temporary file in the executor's
  `c:Tackle.Executor.tmp_dir/1`, which is removed afterwards.
  """
  @spec diff(Path.t(), [String.t()], [option()]) :: {:ok, binary()} | {:error, error()}
  def diff(cwd, args, opts \\ []) do
    executor = Keyword.get(opts, :executor) || Executor.local()
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    file = Path.join(Executor.tmp_dir(executor), temp_name())

    try do
      with {:ok, _output} <- run(cwd, ["diff", "--output=" <> file | args], opts) do
        Executor.read_file(executor, file, max_bytes)
      end
    after
      Executor.delete(executor, file)
    end
  end

  @doc "Formats a command error for people."
  @spec format_error(error()) :: String.t()
  def format_error({:git_failed, status, output}) do
    case String.trim(output) do
      "" -> "git exited with status #{status}"
      message -> "git exited with status #{status}: #{message}"
    end
  end

  def format_error(:timeout), do: "git did not finish in time"
  def format_error(:too_large), do: "git output is too large"
  def format_error(reason), do: Executor.format_reason(reason)

  defp temp_name do
    "tackle-review-#{System.unique_integer([:positive])}-#{:rand.uniform(1_000_000_000)}.diff"
  end

  defp collect(executor, handle, deadline, max_bytes, {chunks, size}) do
    remaining = deadline - System.monotonic_time(:millisecond)

    case Executor.await(executor, handle, min(max(remaining, 0), @poll_interval)) do
      {:data, data} when size + byte_size(data) > max_bytes ->
        Executor.cancel(executor, handle)
        {:error, :too_large}

      {:data, data} ->
        collect(executor, handle, deadline, max_bytes, {[data | chunks], size + byte_size(data)})

      {:exit_status, status} ->
        output = chunks |> Enum.reverse() |> IO.iodata_to_binary()
        if status == 0, do: {:ok, output}, else: {:error, {:git_failed, status, output}}

      {:error, reason} ->
        {:error, reason}

      :timeout when remaining <= 0 ->
        Executor.cancel(executor, handle)
        {:error, :timeout}

      :timeout ->
        collect(executor, handle, deadline, max_bytes, {chunks, size})
    end
  end
end
