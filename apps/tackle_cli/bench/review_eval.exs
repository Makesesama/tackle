# Review benchmark ("option A": fewer tokens per review run). NOT a synthetic
# baseline: it runs real reviews with your configuration, credentials, and
# models, and every review costs what a normal review costs.
#
#   cd apps/tackle_cli
#   mix run --no-start bench/review_eval.exs --check          # validate cases, no model calls
#   mix run --no-start bench/review_eval.exs [options]        # run the benchmark
#
# Each case (bench/review_eval/cases/*.json) is a past commit of this
# repository, possibly with bugs seeded into its added lines. The case is
# checked out in a scratch clone (seed amended into the commit, no refs to
# later commits), and the range `base..head` is reviewed once per variant and
# repeat, in a fresh scope whose working directory is the clone. Findings are
# matched against the known issues by location; tokens, runs, and time come
# from the review's own summary. See bench/review_eval/README.md.
#
# Options:
#   --check              prepare every case and print its units; no review
#   --list-variants      print the variants and exit
#   --variants A,B       variants to run (default: baseline,steps,lean,
#                        low-thinking,single-call,combined)
#   --case ID            only this case (repeatable)
#   --cases DIR          case directory (default: bench/review_eval/cases)
#   --repeat N           runs per case and variant (default 1)
#   --model REF          root model; inheriting stages use it (default: config)
#   --thinking LEVEL     root thinking level (default: config)
#   --cheap-model REF    adds the cheap-detector variant on this model
#   --profile NAME       quiet | default | assertive (default: default)
#   --concurrency N      runs in flight per review (default: the scope's)
#   --limit SECONDS      give up on one review after this long (default 1800)
#   --slack N            lines of tolerance when matching (default 3)
#   --out FILE           JSON Lines results (default: a new file in the tmp dir)
#   --workdir DIR        where case checkouts go (default: a new directory per run
#                        under <tmp>/tackle-review-eval); two runs cannot share one
#   --keep-worktrees     do not remove the case checkouts afterwards
#   --summarize FILE     only print the tables of an existing results file
#
# Under the jail (TACKLE_EXEC_LAUNCHER set) the workdir must be inside the jail
# workspace: set TACKLE_EXEC_WORKSPACE to a directory containing it, or run
# without the jail (the review agents only read).

# Loaded in dependency order; the test environment compiles them instead.
for file <- ~w(case score variant report runner) do
  Code.require_file("review_eval/lib/#{file}.ex", __DIR__)
end

defmodule ReviewEval.Script do
  @moduledoc false

  alias Tackle.Bench.ReviewEval.{Case, Report, Runner, Variant}

  @switches [
    check: :boolean,
    list_variants: :boolean,
    variants: :string,
    case: :keep,
    cases: :string,
    repeat: :integer,
    model: :string,
    thinking: :string,
    cheap_model: :string,
    profile: :string,
    concurrency: :integer,
    limit: :integer,
    slack: :integer,
    out: :string,
    workdir: :string,
    keep_worktrees: :boolean,
    summarize: :string
  ]

  def main(argv) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: @switches)

    if rest != [] or invalid != [] do
      fail("unexpected arguments: #{inspect(rest ++ invalid)}")
    end

    variants = Variant.builtin(cheap_model: opts[:cheap_model])

    cond do
      opts[:list_variants] -> list_variants(variants)
      opts[:summarize] -> summarize(opts[:summarize])
      true -> run(opts, variants)
    end
  end

  defp list_variants(variants) do
    defaults = Variant.default_names()

    for variant <- variants do
      marker = if variant.name in defaults, do: "*", else: " "
      IO.puts("#{marker} #{String.pad_trailing(variant.name, 20)} #{variant.description}")
    end

    IO.puts("\n* run by default")
  end

  defp summarize(path) do
    records =
      path
      |> File.stream!()
      |> Stream.reject(&(String.trim(&1) == ""))
      |> Enum.map(&JSON.decode!/1)

    print_tables(records)
  end

  defp run(opts, variants) do
    repo = git_toplevel()
    cases_dir = Keyword.get(opts, :cases, Path.join(__DIR__, "review_eval/cases"))
    tmp = Path.join(System.tmp_dir!(), "tackle-review-eval")
    stamp = DateTime.utc_now() |> DateTime.to_iso8601(:basic) |> String.replace(~r/[^0-9TZ]/, "")
    default_workdir = Path.join(tmp, "worktrees-#{stamp}-#{System.pid()}")
    workdir = Keyword.get(opts, :workdir, default_workdir)

    with {:ok, cases} <- Case.load_dir(cases_dir),
         {:ok, cases} <- select_cases(cases, Keyword.get_values(opts, :case)),
         {:ok, variants} <- Variant.select(variants, variant_names(opts)),
         {:ok, profile} <- profile(opts[:profile]) do
      runner_opts = [
        cases: cases,
        variants: variants,
        repo: repo,
        workdir: workdir,
        keep_worktrees: Keyword.get(opts, :keep_worktrees, false),
        repeat: Keyword.get(opts, :repeat, 1),
        model: opts[:model],
        thinking: opts[:thinking],
        limit_ms: Keyword.get(opts, :limit, 1_800) * 1_000,
        slack: Keyword.get(opts, :slack, 3),
        review_opts:
          [profile: profile] ++
            if(opts[:concurrency], do: [max_concurrency: opts[:concurrency]], else: [])
      ]

      result =
        Runner.with_workdir(workdir, fn ->
          if opts[:check], do: check(runner_opts), else: bench(runner_opts, opts, tmp, stamp)
        end)

      # A per-run directory is left behind only when it still holds checkouts.
      if workdir == default_workdir, do: File.rmdir(workdir)
      finish(result)
    else
      {:error, reason} -> fail("review_eval: #{inspect(reason)}")
    end
  end

  # `check/1` and `bench/4` return instead of halting, so the workdir lock is
  # released first.
  defp finish(:ok), do: :ok
  defp finish({:halt, status}), do: System.halt(status)

  defp finish({:error, {:workdir_in_use, lock}}),
    do:
      fail("review_eval: another run is using #{Path.dirname(lock)} (delete #{lock} if none is)")

  defp finish({:error, reason}), do: fail("review_eval: #{inspect(reason)}")

  defp check(runner_opts) do
    case Runner.check(runner_opts) do
      {:ok, descriptions} ->
        Enum.each(descriptions, fn d ->
          IO.puts(
            "#{d.case}: #{d.files} files, #{d.changed_lines} changed lines, " <>
              "#{d.units} units, #{d.batches} detector runs"
          )

          Enum.each(d.issues, &IO.puts("    issue #{&1}"))

          if d.uncovered != [],
            do: IO.puts("    NOT ON CHANGED LINES: #{Enum.join(d.uncovered, ", ")}")
        end)

        if Enum.any?(descriptions, &(&1.uncovered != [])), do: {:halt, 1}, else: :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp bench(runner_opts, opts, tmp, stamp) do
    out = Keyword.get(opts, :out, Path.join(tmp, "results-#{stamp}.jsonl"))
    IO.puts(:stderr, "results: #{out}")

    case Runner.run(Keyword.put(runner_opts, :out, out)) do
      {:ok, records} ->
        print_tables(records)
        IO.puts("\nresults: #{out}")

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp print_tables(records) do
    IO.puts(Report.table(Report.summarize(records)))
    IO.puts("")
    IO.puts(Report.case_table(records))
  end

  defp select_cases(cases, []), do: {:ok, cases}

  defp select_cases(cases, ids) do
    case ids -- Enum.map(cases, & &1.id) do
      [] -> {:ok, Enum.filter(cases, &(&1.id in ids))}
      unknown -> {:error, {:unknown_cases, unknown}}
    end
  end

  defp variant_names(opts) do
    case opts[:variants] do
      nil -> Variant.default_names()
      names -> names |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end
  end

  defp profile(nil), do: {:ok, :default}

  defp profile(name) when name in ~w(quiet default assertive),
    do: {:ok, String.to_existing_atom(name)}

  defp profile(name), do: {:error, {:invalid_profile, name}}

  defp git_toplevel do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {path, 0} -> String.trim(path)
      {out, _status} -> fail("not inside a Git repository: #{out}")
    end
  end

  defp fail(message) do
    IO.puts(:stderr, message)
    System.halt(2)
  end
end

ReviewEval.Script.main(System.argv())
