defmodule Tackle.LocalReview.History do
  @moduledoc """
  Personal, append-only history of code reviews and their findings.

  Each Git repository has its own directory under `TACKLE_HOME`, named by
  `Tackle.Paths.project_key/1` of the repository root, so every
  subdirectory of a repository shares one history:

      $TACKLE_HOME/review/--home-user-project--/
      ├── runs.jsonl        one line per review run
      └── findings.jsonl    one line per finding event

  Directories are private to the current user and files are created with
  the same restrictive permissions as session storage
  (`Tackle.Session.Storage`): findings quote code and may describe
  vulnerabilities. The history is never meant to be committed.

  ## Runs

  `record_run/4` appends a run line with what was reviewed (change mode,
  base and head), the profile and samples, summary counts, digests of the
  rules and stage prompts in effect (to compare runs across prompt and rule
  changes), the cost settings (unit size, batching, per-stage models and
  thinking levels), the runs, token usage, and wall time of each stage, and
  the total token usage and wall time, so the cost and quality of settings
  can be compared across runs. It also appends one `shown` event per shown
  finding and one `rejected` event per finding the verifier rejected, so
  the rejection rate can be inspected later.

  ## Finding events

  Every line of `findings.jsonl` is a JSON object with `"version"`, `"at"`
  (ISO 8601, UTC), `"event"`, `"fingerprint"` (see
  `Tackle.Review.Finding.fingerprint/2`), and `"run_id"` (or `null`):

    * `shown` - the finding was shown; carries `"finding"`;
    * `rejected` - the verifier rejected it; carries `"finding"` and
      `"evidence"`;
    * `useful`, `not_useful`, `dismissed`, `fixed` - outcomes reported by
      the user through `record_outcome/4`; may carry a `"note"`.

  `fingerprints/2` reads back the fingerprints with given events, which
  `Tackle.LocalReview` passes to `Tackle.Review.run/2` as
  `:known_fingerprints` to skip dismissed (or already shown) findings.

  Lines are appended with one write each. A line that cannot be decoded,
  such as a partial line left by a crash, is skipped when reading; the next
  write first ends such a line, so the lines after it are kept.
  """

  alias Tackle.Lib.Usage
  alias Tackle.Paths
  alias Tackle.Review.{Change, Finding, Result}
  alias Tackle.Runtime.ID
  alias Tackle.Session.Storage

  @version 1
  @review_dir "review"
  @runs_file "runs.jsonl"
  @findings_file "findings.jsonl"

  @outcomes [:useful, :not_useful, :dismissed, :fixed]
  @events [:shown, :rejected | @outcomes]

  @usage_fields [
    :input_tokens,
    :output_tokens,
    :reasoning_tokens,
    :cache_read_tokens,
    :cache_write_tokens,
    :total_tokens,
    :cost,
    :currency
  ]

  @enforce_keys [:root, :project_key, :dir]
  defstruct [:root, :project_key, :dir]

  @typedoc """
  An opened history: the repository `root` it belongs to, its
  `project_key`, and the directory `dir` holding its files. Opening does
  not touch the file system.
  """
  @type t :: %__MODULE__{root: Path.t(), project_key: String.t(), dir: Path.t()}

  @typedoc "An outcome reported for a shown finding."
  @type outcome :: :useful | :not_useful | :dismissed | :fixed

  @typedoc "A finding event: recorded with a run (`:shown`, `:rejected`) or an outcome."
  @type event :: :shown | :rejected | outcome()

  @typedoc """
  Options of `open/2`: `:home`, the Tackle home directory, `nil` when it
  could not be resolved (as in `Tackle.Paths.homes/1`); default:
  `Tackle.Paths.home/1` of the process environment.
  """
  @type open_option :: {:home, Path.t() | nil}

  @typedoc "Options of `record_outcome/4`: `:run_id` and a free-text `:note`."
  @type outcome_option :: {:run_id, String.t()} | {:note, String.t()}

  @doc "Returns the outcomes `record_outcome/4` accepts."
  @spec outcomes() :: [outcome()]
  def outcomes, do: @outcomes

  @doc "Returns every finding event, the outcomes included."
  @spec events() :: [event()]
  def events, do: @events

  @doc """
  Opens the history of the repository whose root is `root`.

  Fails only when the Tackle home cannot be resolved or an option is
  invalid (`{:invalid_home, value}`, or `{:invalid_option, key, value}`
  for another option); files are created on the first write.
  """
  @spec open(Path.t(), [open_option()]) :: {:ok, t()} | {:error, term()}
  def open(root, opts \\ [])

  def open(root, opts) when is_binary(root) and root != "" and is_list(opts) do
    with {:ok, home} <- home(opts) do
      root = Path.expand(root)
      key = Paths.project_key(root)
      {:ok, %__MODULE__{root: root, project_key: key, dir: Path.join([home, @review_dir, key])}}
    end
  end

  def open(root, _opts), do: {:error, {:invalid_root, root}}

  @doc "Returns the path of the run log."
  @spec runs_path(t()) :: Path.t()
  def runs_path(%__MODULE__{dir: dir}), do: Path.join(dir, @runs_file)

  @doc "Returns the path of the finding event log."
  @spec findings_path(t()) :: Path.t()
  def findings_path(%__MODULE__{dir: dir}), do: Path.join(dir, @findings_file)

  @doc """
  Records a finished review: a run line, then a `shown` event for every
  shown finding and a `rejected` event for every rejected one.

  The rules and stage prompts in effect are recorded by the digests in the
  result's summary (see `Tackle.Review.Result`). Returns the new run's id.
  """
  @spec record_run(t(), Change.t(), Result.t()) :: {:ok, String.t()} | {:error, term()}
  def record_run(%__MODULE__{} = history, %Change{} = change, %Result{} = result) do
    id = ID.generate()
    at = now()

    run = %{
      "version" => @version,
      "id" => id,
      "at" => at,
      "root" => history.root,
      "change" => %{
        "mode" => Atom.to_string(change.mode),
        "base_ref" => change.base_ref,
        "base_sha" => change.base_sha,
        "head_sha" => to_string(change.head_sha)
      },
      "profile" => Atom.to_string(result.summary.profile),
      "samples" => result.summary.samples,
      "summary" => summary(result.summary),
      "settings" => settings(Map.get(result.summary, :settings)),
      "stages" => stages(Map.get(result.summary, :stages, %{})),
      "duration_ms" => Map.get(result.summary, :duration_ms),
      "rules" => result.summary |> Map.get(:rules, []) |> Enum.map(&rule/1),
      "prompts" => Map.get(result.summary, :prompts, %{}),
      "usage" => usage(result.usage)
    }

    shown =
      Enum.map(Result.findings(result), fn finding ->
        finding
        |> finding_event(:shown, id, at)
        |> Map.put("finding", finding_json(finding))
      end)

    rejected =
      Enum.map(result.rejected, fn %{finding: finding, evidence: evidence} ->
        finding
        |> finding_event(:rejected, id, at)
        |> Map.merge(%{"finding" => finding_json(finding), "evidence" => evidence})
      end)

    with :ok <- append(history, runs_path(history), [run]),
         :ok <- append(history, findings_path(history), shown ++ rejected) do
      {:ok, id}
    end
  end

  @doc """
  Records an outcome for the finding with `fingerprint`.

  Returns `{:error, {:invalid_outcome, outcome}}` for anything but
  `outcomes/0`. See `t:outcome_option/0`.
  """
  @spec record_outcome(t(), String.t(), outcome(), [outcome_option()]) :: :ok | {:error, term()}
  def record_outcome(history, fingerprint, outcome, opts \\ [])

  def record_outcome(%__MODULE__{} = history, fingerprint, outcome, opts)
      when is_binary(fingerprint) and fingerprint != "" and outcome in @outcomes do
    event = %{
      "version" => @version,
      "at" => now(),
      "event" => Atom.to_string(outcome),
      "fingerprint" => fingerprint,
      "run_id" => Keyword.get(opts, :run_id)
    }

    event =
      case Keyword.get(opts, :note) do
        note when is_binary(note) -> Map.put(event, "note", note)
        _none -> event
      end

    append(history, findings_path(history), [event])
  end

  def record_outcome(%__MODULE__{}, fingerprint, outcome, _opts)
      when is_binary(fingerprint) and fingerprint != "",
      do: {:error, {:invalid_outcome, outcome}}

  def record_outcome(%__MODULE__{}, fingerprint, _outcome, _opts),
    do: {:error, {:invalid_fingerprint, fingerprint}}

  @doc "Reads the recorded runs, oldest first, as decoded JSON objects."
  @spec runs(t()) :: {:ok, [map()]} | {:error, term()}
  def runs(%__MODULE__{} = history) do
    read(runs_path(history), &(is_binary(&1["id"]) and is_map(&1["summary"])))
  end

  @doc """
  Reads the finding events, oldest first, as decoded JSON objects (see the
  module documentation). Events of unknown kinds are skipped.
  """
  @spec finding_events(t()) :: {:ok, [map()]} | {:error, term()}
  def finding_events(%__MODULE__{} = history) do
    known = Enum.map(@events, &Atom.to_string/1)
    read(findings_path(history), &(&1["event"] in known and is_binary(&1["fingerprint"])))
  end

  @doc """
  Returns the fingerprints that have at least one of `events` recorded,
  such as `[:dismissed]` for findings not to report again.
  """
  @spec fingerprints(t(), [event()]) :: {:ok, MapSet.t(String.t())} | {:error, term()}
  def fingerprints(%__MODULE__{} = history, events) when is_list(events) do
    case events -- @events do
      [] ->
        wanted = Enum.map(events, &Atom.to_string/1)

        with {:ok, entries} <- finding_events(history) do
          {:ok, fingerprints_with(entries, wanted)}
        end

      invalid ->
        {:error, {:invalid_events, invalid}}
    end
  end

  defp fingerprints_with(entries, wanted) do
    for %{"event" => event, "fingerprint" => fingerprint} <- entries,
        event in wanted,
        into: MapSet.new(),
        do: fingerprint
  end

  @doc "Describes a history error in one line."
  @spec format_error(term()) :: String.t()
  def format_error({:mkdir_failed, path, reason}),
    do: "cannot create #{path}: #{:file.format_error(reason)}"

  def format_error({:chmod_failed, path, reason}),
    do: "cannot restrict #{path}: #{:file.format_error(reason)}"

  def format_error({:write_failed, path, reason}),
    do: "cannot write #{path}: #{:file.format_error(reason)}"

  def format_error({:read_failed, path, reason}),
    do: "cannot read #{path}: #{:file.format_error(reason)}"

  def format_error(:user_home_unavailable),
    do: "the home directory is unavailable; set TACKLE_HOME"

  def format_error(reason), do: inspect(reason)

  ## Writing

  defp append(_history, _path, []), do: :ok

  defp append(history, path, entries) do
    with {:ok, data} <- encode(entries),
         :ok <- Storage.ensure_private_dir(Path.dirname(history.dir)),
         :ok <- Storage.ensure_private_dir(history.dir),
         :ok <- create_private(path),
         {:ok, separator} <- separator(path) do
      case File.write(path, [separator | data], [:append, :binary]) do
        :ok -> :ok
        {:error, reason} -> {:error, {:write_failed, path, reason}}
      end
    end
  end

  # A crash or a full disk can leave the file ending in a partial line.
  # Appending to it would glue the next good line onto the fragment, so
  # both would be skipped when reading; a newline ends the fragment first.
  defp separator(path) do
    case File.open(path, [:read, :binary, :raw], &last_byte/1) do
      {:ok, {:ok, "\n"}} -> {:ok, []}
      {:ok, {:ok, _byte}} -> {:ok, "\n"}
      {:ok, :empty} -> {:ok, []}
      {:ok, {:error, reason}} -> {:error, {:read_failed, path, reason}}
      {:error, reason} -> {:error, {:read_failed, path, reason}}
    end
  end

  defp last_byte(io) do
    case :file.position(io, :eof) do
      {:ok, 0} -> :empty
      {:ok, size} -> :file.pread(io, size - 1, 1)
      {:error, reason} -> {:error, reason}
    end
  end

  # The file is restricted before anything is written to it.
  defp create_private(path) do
    with :ok <- touch(path) do
      case File.chmod(path, Storage.file_mode()) do
        :ok -> :ok
        {:error, reason} -> {:error, {:chmod_failed, path, reason}}
      end
    end
  end

  defp touch(path) do
    case File.write(path, "", [:append, :binary]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write_failed, path, reason}}
    end
  end

  defp encode(entries) do
    {:ok, Enum.map(entries, &[JSON.encode_to_iodata!(&1), ?\n])}
  rescue
    exception -> {:error, {:encode_failed, Exception.message(exception)}}
  end

  defp finding_event(%Finding{fingerprint: fingerprint}, event, run_id, at) do
    %{
      "version" => @version,
      "at" => at,
      "event" => Atom.to_string(event),
      "fingerprint" => fingerprint,
      "run_id" => run_id
    }
  end

  defp finding_json(%Finding{} = finding) do
    %{
      "title" => finding.title,
      "category" => Atom.to_string(finding.category),
      "severity" => Atom.to_string(finding.severity),
      "blocking" => finding.blocking,
      "confidence" => finding.confidence,
      "rule_id" => finding.rule_id,
      "location" => %{
        "path" => finding.location.path,
        "side" => Atom.to_string(finding.location.side),
        "start_line" => finding.location.start_line,
        "end_line" => finding.location.end_line
      },
      "trigger" => finding.trigger,
      "body" => finding.body,
      "suggestion" => finding.suggestion,
      "support" => finding.support,
      "verdict" => finding.verdict && Atom.to_string(finding.verdict)
    }
  end

  defp summary(summary) do
    %{
      "units" => summary.units,
      "files" => summary.files,
      "skipped" => length(summary.skipped),
      "failed_units" => length(summary.failed_units),
      "incomplete_units" => length(summary.incomplete_units),
      "detected" => summary.detected,
      "candidates" => summary.candidates,
      "confirmed" => summary.confirmed,
      "uncertain" => summary.uncertain,
      "rejected" => summary.rejected,
      "verification_failures" => length(summary.verification_failures),
      "scoring_failures" => length(summary.scoring_failures),
      "blocking" => summary.blocking,
      "optional" => summary.optional,
      "verdict" => Atom.to_string(summary.verdict)
    }
  end

  defp settings(nil), do: nil

  defp settings(settings) do
    Map.new(settings, fn {key, value} -> {Atom.to_string(key), json_value(value)} end)
  end

  defp json_value(value) when is_map(value),
    do: Map.new(value, fn {key, inner} -> {to_string(key), json_value(inner)} end)

  defp json_value(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp json_value(value), do: value

  defp stages(stages) do
    Map.new(stages, fn {stage, stats} ->
      {Atom.to_string(stage),
       %{
         "runs" => stats.runs,
         "failed" => stats.failed,
         "duration_ms" => stats.duration_ms,
         "usage" => usage(stats.usage)
       }}
    end)
  end

  defp rule(%{id: id, source: source, status: status, digest: digest}) do
    %{
      "id" => id,
      "source" => Atom.to_string(source),
      "status" => Atom.to_string(status),
      "digest" => digest
    }
  end

  defp usage(%Usage{} = usage) do
    usage
    |> Map.take(@usage_fields)
    |> Enum.filter(fn {_field, value} -> is_number(value) or is_binary(value) end)
    |> Map.new(fn {field, value} -> {Atom.to_string(field), value} end)
  end

  defp usage(_usage), do: %{}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  ## Reading

  defp read(path, valid?) do
    case File.read(path) do
      {:ok, content} ->
        entries =
          for line <- String.split(content, "\n", trim: true),
              {:ok, %{} = entry} <- [decode(line)],
              valid?.(entry),
              do: entry

        {:ok, entries}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:read_failed, path, reason}}
    end
  end

  defp decode(line) do
    JSON.decode(line)
  rescue
    _exception -> :error
  end

  defp home(opts) do
    case {Keyword.fetch(opts, :home), Keyword.delete(opts, :home)} do
      {_home, [{key, value} | _rest]} -> {:error, {:invalid_option, key, value}}
      {home, []} -> fetch_home(home)
    end
  end

  defp fetch_home({:ok, home}) when is_binary(home) and home != "", do: {:ok, Path.expand(home)}
  defp fetch_home({:ok, nil}), do: {:error, :user_home_unavailable}
  defp fetch_home({:ok, other}), do: {:error, {:invalid_home, other}}
  defp fetch_home(:error), do: Paths.home()
end
