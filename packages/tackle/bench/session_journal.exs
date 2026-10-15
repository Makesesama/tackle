# Durable session journal benchmark (synthetic baseline).
#
# Measures what a durable Tackle session pays for committing every durable fact
# synchronously through `Tackle.Session.Journal`, so the planned changes
# (projection/catalog off the commit path, group commit, async append with a
# durability watermark) can be compared against the same numbers. Every model
# and tool in this script is a deterministic in-process fake: no credentials,
# network, or paid services are used. The numbers are a synthetic baseline for
# this machine and filesystem, not a production latency claim.
#
# Sections:
#
#   A. Raw floor: `:disk_log` log-only vs log+sync per commit for ~200 B, 4 KB,
#      64 KB, and 1 MB payloads (internal format, halt mode, like the journal),
#      raw `:file.write` + fsync/fdatasync for reference, an fsync with nothing
#      pending (what the provider gate flush costs), and term_to_binary vs
#      JSON.encode! for the same commit envelope.
#   B1. Journal API: a real `Tackle.Session.Journal` owner (watchdog included)
#       timing begin_turn, append_message (user, assistant, tool result),
#       tool_started, settle_turn, and flush individually, bucketed by session
#       length (commit #10, #1000, #5000).
#   B2. Commit stages in-process: the public pieces the journal's private
#       `commit/3` calls, in the same order and on a growing projection —
#       event encoding, Log.commit, Log.validate_commit + Codec.validate,
#       term_to_binary (what `:disk_log.log/2` does in the caller),
#       Projection.apply_commit, the catalog summary (rebuilt from the public
#       Projection.metadata/1 because `build_summary/1` is private; search text
#       is built only when searching), and the Catalog.record/1 cast. The append/sync themselves are
#       section A. Watchdog `stage` casts and the watchdog request hop are not
#       separately reachable; the report estimates the hop as B1 flush minus
#       the raw empty-sync floor and decomposes B1 into B2 + the rest.
#   C. End-to-end ReAct turn through Tackle.Runtime: a fake LLM returns K tool
#      calls for N iterations, then a final answer; a fake no-op tool. Each
#      scenario runs ephemeral (no journal) and durable; the report gives the
#      durable − ephemeral overhead per turn, per provider call, and per commit,
#      the journal syncs actually issued per turn (traced), the journal growth,
#      and the block device's bytes written per turn (/proc/diskstats, noisy),
#      and compares it against a fully serialized estimate from B1.
#   E. Contention: a background writer streams large chunks + fsync to the same
#      filesystem while B1/C run, approximating a slow, busy disk.
#
#      WARNING: contention slows every fsync on that filesystem, including the
#      journals of any live Tackle session whose TACKLE_HOME is on the same
#      disk. A live session fails closed when a journal stage exceeds its
#      watchdog bound, so do not run contention mode (BENCH_CONTENTION=1/both)
#      while an agent session on the same disk is running, including one that
#      launched this script. A contended run took down the parent session
#      once; the cause was never confirmed.
#
# Storage defaults to `_bench_tmp/` inside this package (the repository's ext4
# disk; /tmp and $HOME may be tmpfs where fsync is free). Everything written
# there is removed when the run ends. `TACKLE_HOME` for the run also points
# there, so the user's real sessions and catalog are never touched.
#
# Run from packages/tackle (dev env; a default run takes ~15 s, `both` ~30 s):
#
#     mix run --no-start bench/session_journal.exs
#     BENCH_CONTENTION=both mix run --no-start bench/session_journal.exs
#
# `--no-start` is preferred: the script configures TACKLE_HOME and the auth
# file before starting `:tackle`. Plain `mix run bench/session_journal.exs`
# also works; the script then restarts `:tackle` with the bench configuration
# (the first start reads, but never writes, the default TACKLE_HOME catalog).
#
# Knobs (environment variables):
#
#   BENCH_DIR                  data directory root (default: <pkg>/_bench_tmp)
#   BENCH_OUT                  JSON results path
#                              (default: _build/bench/session_journal-<ts>.json,
#                              under the git-ignored _build directory)
#   BENCH_CONTENTION           0 = quiet only (default), 1 = contended only,
#                              both = quiet then contended
#   BENCH_CONTENTION_WRITERS   background writer processes (default 1)
#   BENCH_CONTENTION_CHUNK_MB  bytes written between fsyncs (default 16)
#   BENCH_CONTENTION_FILE_MB   rotate each writer file at this size (default 512)
#   BENCH_CONTENTION_MBPS      total write-rate cap in MiB/s, 0 = unthrottled
#                              (default 400; bounds SSD wear: a contended run
#                              writes roughly rate × contended seconds)
#   BENCH_CONTENTION_COMMITS   B1 commits under contention (default 1000)
#   BENCH_RAW_ITERS            A: operations per payload size (default 300)
#   BENCH_RAW_LARGE_ITERS      A: operations for the 1 MB payload (default 60)
#   BENCH_ENCODE_ITERS         A: encode samples per size (default 1000)
#   BENCH_COMMITS              B1/B2: commits in the session (default 5000)
#   BENCH_CHECKPOINTS          B: session-length checkpoints (default 10,1000,5000)
#   BENCH_WINDOW               B: commits per checkpoint window (default 100)
#   BENCH_TURN_COMMITS         B: commits per turn before settling (default 50)
#   BENCH_MSG_BYTES            B: message content bytes (default 1024)
#   BENCH_FLUSH_SAMPLES        B1: flush/status samples (default 200)
#   BENCH_E2E_TURNS            C: measured turns per scenario/mode (default 30)
#   BENCH_E2E_WARMUP           C: unmeasured warmup turns (default 2)
#   BENCH_E2E_ITERS            C: tool iterations N per turn (default 4)
#   BENCH_E2E_PARALLEL         C: tool calls K in the parallel case (default 8)
#   BENCH_E2E_PAYLOAD          C: tool result content bytes (default 1024)
#   BENCH_KEEP=1               keep the data directory for inspection

defmodule Bench.Knobs do
  @moduledoc false

  def load do
    package = Path.expand("..", __DIR__)
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")

    %{
      package: package,
      stamp: stamp,
      dir: env("BENCH_DIR", Path.join(package, "_bench_tmp")) |> Path.expand(),
      default_dir?: System.get_env("BENCH_DIR") in [nil, ""],
      out:
        env("BENCH_OUT", Path.join([package, "_build", "bench", "session_journal-#{stamp}.json"])),
      contention: contention_mode(env("BENCH_CONTENTION", "0")),
      contention_writers: int("BENCH_CONTENTION_WRITERS", 1),
      contention_chunk_mb: int("BENCH_CONTENTION_CHUNK_MB", 16),
      contention_file_mb: int("BENCH_CONTENTION_FILE_MB", 512),
      contention_mbps: int("BENCH_CONTENTION_MBPS", 400),
      contention_commits: int("BENCH_CONTENTION_COMMITS", 1000),
      raw_iters: int("BENCH_RAW_ITERS", 300),
      raw_large_iters: int("BENCH_RAW_LARGE_ITERS", 60),
      encode_iters: int("BENCH_ENCODE_ITERS", 1000),
      commits: int("BENCH_COMMITS", 5000),
      checkpoints: ints("BENCH_CHECKPOINTS", [10, 1000, 5000]),
      window: int("BENCH_WINDOW", 100),
      turn_commits: int("BENCH_TURN_COMMITS", 50),
      msg_bytes: int("BENCH_MSG_BYTES", 1024),
      flush_samples: int("BENCH_FLUSH_SAMPLES", 200),
      e2e_turns: int("BENCH_E2E_TURNS", 30),
      e2e_warmup: int("BENCH_E2E_WARMUP", 2),
      e2e_iters: int("BENCH_E2E_ITERS", 4),
      e2e_parallel: int("BENCH_E2E_PARALLEL", 8),
      e2e_payload: int("BENCH_E2E_PAYLOAD", 1024),
      keep?: env("BENCH_KEEP", "0") == "1"
    }
  end

  defp contention_mode(value) do
    case String.downcase(value) do
      v when v in ["0", "", "false", "no"] ->
        [:quiet]

      v when v in ["1", "true", "yes", "only"] ->
        [:contended]

      "both" ->
        [:quiet, :contended]

      other ->
        raise ArgumentError, "BENCH_CONTENTION must be 0, 1, or both, got #{inspect(other)}"
    end
  end

  defp env(name, default) do
    case System.get_env(name) do
      value when value in [nil, ""] -> default
      value -> value
    end
  end

  defp int(name, default) do
    case Integer.parse(env(name, Integer.to_string(default))) do
      {value, ""} when value >= 0 -> value
      _other -> raise ArgumentError, "#{name} must be a non-negative integer"
    end
  end

  defp ints(name, default) do
    case System.get_env(name) do
      value when value in [nil, ""] ->
        default

      value ->
        value |> String.split(",", trim: true) |> Enum.map(&String.to_integer(String.trim(&1)))
    end
  end
end

defmodule Bench.Stats do
  @moduledoc false

  @doc "Runs `fun` and returns `{microseconds, result}`."
  def time(fun) do
    started = System.monotonic_time()
    result = fun.()
    {us(System.monotonic_time() - started), result}
  end

  def us(native), do: System.convert_time_unit(native, :native, :nanosecond) / 1000

  def summarize([]), do: %{n: 0}

  def summarize(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    tuple = List.to_tuple(sorted)
    total = Enum.sum(sorted)

    %{
      n: n,
      min: elem(tuple, 0),
      p50: pct(tuple, n, 50),
      p95: pct(tuple, n, 95),
      p99: pct(tuple, n, 99),
      max: elem(tuple, n - 1),
      mean: total / n,
      total: total
    }
  end

  defp pct(tuple, n, p), do: elem(tuple, max(0, min(n - 1, ceil(p / 100 * n) - 1)))

  def fmt(nil), do: "—"
  def fmt(us) when us >= 1_000_000, do: num(us / 1_000_000) <> " s"
  def fmt(us) when us >= 1000, do: num(us / 1000) <> " ms"
  def fmt(us), do: num(us) <> " µs"

  def num(value) when is_integer(value), do: Integer.to_string(value)
  def num(value) when abs(value) >= 100, do: :erlang.float_to_binary(value * 1.0, decimals: 0)
  def num(value) when abs(value) >= 10, do: :erlang.float_to_binary(value * 1.0, decimals: 1)
  def num(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)

  def bytes(b) when b >= 1024 * 1024, do: num(b / (1024 * 1024)) <> " MiB"
  def bytes(b) when b >= 1024, do: num(b / 1024) <> " KiB"
  def bytes(b), do: "#{round(b)} B"

  def row(cells), do: "| " <> Enum.join(cells, " | ") <> " |"

  def table(header, rows) do
    sep = row(Enum.map(header, fn _ -> "---" end))
    Enum.join([row(header), sep | Enum.map(rows, &row/1)], "\n")
  end

  def stat_cells(%{n: 0}), do: ["0", "—", "—", "—", "—", "—"]

  def stat_cells(s),
    do: [Integer.to_string(s.n), fmt(s.p50), fmt(s.p95), fmt(s.p99), fmt(s.max), fmt(s.mean)]

  def stat_header, do: ["n", "p50", "p95", "p99", "max", "mean"]
end

defmodule Bench.Text do
  @moduledoc false
  @words ~w(alpha beta gamma delta journal commit sync durable session tool result
            message assistant provider projection catalog summary latency elixir otp)

  @doc "Deterministic word text of exactly `bytes` bytes; `seed` rotates the words."
  def of_size(bytes, seed \\ 0)
  def of_size(bytes, _seed) when bytes <= 0, do: ""

  def of_size(bytes, seed) do
    {head, tail} = Enum.split(@words, rem(seed, length(@words)))
    base = Enum.join(tail ++ head, " ") <> " "
    base |> :binary.copy(div(bytes, byte_size(base)) + 1) |> binary_part(0, bytes)
  end
end

defmodule Bench.FakeLLM do
  @moduledoc false
  # Deterministic adapter: K tool calls per step for N steps, then a final answer.
  @behaviour Tackle.Lib.LLM

  @impl true
  def adapter_id, do: "bench"

  @impl true
  def models, do: ["fake"]

  @impl true
  def model_info(_model), do: %{context_window: 100_000_000, max_output_tokens: 100_000}

  @impl true
  def generate(_schema, opts) do
    messages = Keyword.get(opts, :messages, [])
    iterations = Keyword.get(opts, :bench_iterations, 0)
    calls = Keyword.get(opts, :bench_tool_calls, 1)
    turn = Enum.count(messages, &(role(&1) == :user))

    done =
      messages
      |> Enum.reverse()
      |> Enum.take_while(&(role(&1) != :user))
      |> Enum.count(&(role(&1) == :assistant))

    data =
      if done < iterations do
        tool_calls =
          for index <- 1..calls//1 do
            %{
              "id" => "call-#{turn}-#{done}-#{index}",
              "name" => "bench_noop",
              "arguments" => %{"i" => index}
            }
          end

        %{"content" => nil, "tool_calls" => tool_calls}
      else
        %{"content" => "done", "tool_calls" => []}
      end

    {:ok, %{data: data, usage: nil, model: Keyword.fetch!(opts, :model), provider: "bench"}}
  end

  defp role(%{role: role}), do: role
  defp role(%{"role" => "user"}), do: :user
  defp role(%{"role" => "assistant"}), do: :assistant
  defp role(%{"role" => "tool"}), do: :tool
  defp role(_message), do: nil
end

defmodule Bench.NoopTool do
  @moduledoc false
  @behaviour Tackle.Lib.Tool

  @impl true
  def name, do: "bench_noop"

  @impl true
  def description, do: "Returns a fixed payload without side effects."

  @impl true
  def parameters_schema, do: [i: [type: :integer]]

  @impl true
  def execute(_args, _context), do: {:ok, :persistent_term.get({Bench, :tool_payload})}
end

defmodule Bench.ReadOnlyTool do
  @moduledoc false
  # Same tool, declared read-only (`Tackle.Lib.Tool.effect/1`), so a durable
  # session may run it without syncing its intent first. No `@impl`, so the
  # script also compiles against library versions without the callback.
  @behaviour Tackle.Lib.Tool

  @impl true
  def name, do: "bench_noop"

  @impl true
  def description, do: "Returns a fixed payload without side effects."

  @impl true
  def parameters_schema, do: [i: [type: :integer]]

  def effect, do: :read_only

  @impl true
  def execute(_args, _context), do: {:ok, :persistent_term.get({Bench, :tool_payload})}
end

defmodule Bench.Contention do
  @moduledoc false
  # Background writers: append large chunks and fsync in a loop on the same
  # filesystem, rotating files at a size cap so the disk is never filled.

  def start(_dir, 0, _chunk_mb, _file_mb, _mbps), do: []

  def start(dir, writers, chunk_mb, file_mb, mbps) do
    File.mkdir_p!(dir)
    chunk = :crypto.strong_rand_bytes(chunk_mb * 1024 * 1024)

    for index <- 1..writers do
      path = Path.join(dir, "contention-#{index}.bin")
      # Each writer gets an equal share of the byte-rate cap (0 = unthrottled).
      rate = if mbps > 0, do: mbps * 1024 * 1024 / writers / 1000, else: nil
      spawn_link(fn -> loop_start(path, chunk, file_mb * 1024 * 1024, rate) end)
    end
  end

  def stop(pids) do
    Enum.map(pids, fn pid ->
      ref = Process.monitor(pid)
      send(pid, {:stop, self(), ref})

      receive do
        {^ref, stats} ->
          Process.demonitor(ref, [:flush])
          stats
      after
        60_000 -> %{error: "writer did not stop"}
      end
    end)
  end

  defp loop_start(path, chunk, cap, rate) do
    {:ok, fd} = open(path)

    loop(
      %{
        path: path,
        fd: fd,
        chunk: chunk,
        cap: cap,
        rate: rate,
        size: 0,
        bytes: 0,
        syncs: 0,
        syncs_us: []
      },
      System.monotonic_time()
    )
  end

  # Bytes per millisecond -> how long to pause to stay under the rate cap.
  defp wait_ms(%{rate: nil}, _started), do: 0

  defp wait_ms(state, started) do
    elapsed_ms =
      System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

    max(0, round(state.bytes / state.rate - elapsed_ms))
  end

  defp open(path) do
    _ = File.rm(path)
    :file.open(String.to_charlist(path), [:raw, :binary, :write])
  end

  defp loop(state, started) do
    receive do
      {:stop, from, ref} ->
        :file.close(state.fd)
        File.rm(state.path)
        seconds = Bench.Stats.us(System.monotonic_time() - started) / 1_000_000

        send(
          from,
          {ref,
           %{
             bytes: state.bytes,
             seconds: seconds,
             mb_per_s: state.bytes / (1024 * 1024) / max(seconds, 1.0e-6),
             syncs: state.syncs,
             sync: Bench.Stats.summarize(state.syncs_us)
           }}
        )
    after
      wait_ms(state, started) ->
        :ok = :file.write(state.fd, state.chunk)
        {us, :ok} = Bench.Stats.time(fn -> :file.sync(state.fd) end)
        size = state.size + byte_size(state.chunk)

        state = %{
          state
          | bytes: state.bytes + byte_size(state.chunk),
            syncs: state.syncs + 1,
            syncs_us: [us | state.syncs_us],
            size: size
        }

        state =
          if size >= state.cap do
            :file.close(state.fd)
            {:ok, fd} = open(state.path)
            %{state | fd: fd, size: 0}
          else
            state
          end

        loop(state, started)
    end
  end
end

defmodule Bench.Payload do
  @moduledoc false
  alias Tackle.Lib.Message
  alias Tackle.Session.Codec
  alias Tackle.Session.Log

  @doc "A commit envelope carrying one message.appended event whose ETF is ~`target` bytes."
  def commit_of_size(target) do
    overhead = :erlang.external_size(commit_with(""))
    commit_with(Bench.Text.of_size(max(1, target - overhead)))
  end

  defp commit_with(content) do
    message = Message.tool_result("call-1", "bench_noop", content, id_generator: fn -> "m-1" end)
    {:ok, data} = Codec.encode_message(message)

    Log.commit(
      session_id: "bench-session",
      seq: 1,
      commit_id: "00000000-0000-0000-0000-000000000000",
      written_at: "2026-01-01T00:00:00.000000Z",
      turn_id: "turn-1",
      events: [Log.event("message.appended", %{"message" => data})]
    )
  end
end

defmodule Bench.Raw do
  @moduledoc false
  import Bench.Stats, only: [time: 1, summarize: 1]

  @sizes [{"~200 B", 200}, {"4 KB", 4096}, {"64 KB", 65_536}, {"1 MB", 1_048_576}]

  def run(knobs, dir) do
    File.mkdir_p!(dir)

    sizes =
      for {label, target} <- @sizes do
        iters = if target >= 1_048_576, do: knobs.raw_large_iters, else: knobs.raw_iters
        commit = Bench.Payload.commit_of_size(target)
        etf = :erlang.term_to_binary(commit)

        %{
          label: label,
          target: target,
          etf_bytes: byte_size(etf),
          iters: iters,
          log_only: log_only(dir, commit, iters),
          log_sync: log_sync(dir, commit, iters),
          raw_fsync: raw_write(dir, etf, iters, :sync),
          raw_fdatasync: raw_write(dir, etf, iters, :datasync)
        }
      end

    %{
      sizes: sizes,
      empty_sync: empty_sync(dir, knobs.raw_iters),
      encode: encode(knobs.encode_iters)
    }
  end

  def quick_sync(dir, iters) do
    File.mkdir_p!(dir)

    for {label, target} <- Enum.take(@sizes, 2) do
      commit = Bench.Payload.commit_of_size(target)
      %{label: label, log_sync: log_sync(dir, commit, iters)}
    end
  end

  defp open_log(dir) do
    path = Path.join(dir, "raw-#{System.unique_integer([:positive])}.dlog")
    name = {:bench_raw, make_ref()}

    {:ok, ^name} =
      :disk_log.open(
        name: name,
        file: String.to_charlist(path),
        type: :halt,
        format: :internal,
        mode: :read_write,
        repair: false,
        size: :infinity
      )

    {name, path}
  end

  defp close_log({name, path}) do
    :ok = :disk_log.close(name)
    File.rm!(path)
  end

  defp log_only(dir, commit, iters) do
    {name, _path} = log = open_log(dir)
    samples = for _ <- 1..iters//1, do: elem(time(fn -> :ok = :disk_log.log(name, commit) end), 0)
    :ok = :disk_log.sync(name)
    close_log(log)
    summarize(samples)
  end

  defp log_sync(dir, commit, iters) do
    {name, _path} = log = open_log(dir)

    samples =
      for _ <- 1..iters//1 do
        {log_us, :ok} = time(fn -> :disk_log.log(name, commit) end)
        {sync_us, :ok} = time(fn -> :disk_log.sync(name) end)
        {log_us, sync_us}
      end

    close_log(log)

    %{
      total: summarize(Enum.map(samples, fn {l, s} -> l + s end)),
      log: summarize(Enum.map(samples, &elem(&1, 0))),
      sync: summarize(Enum.map(samples, &elem(&1, 1)))
    }
  end

  defp raw_write(dir, etf, iters, kind) do
    path = Path.join(dir, "raw-#{System.unique_integer([:positive])}.bin")
    {:ok, fd} = :file.open(String.to_charlist(path), [:raw, :binary, :append])

    samples =
      for _ <- 1..iters//1 do
        elem(
          time(fn ->
            :ok = :file.write(fd, etf)
            :ok = apply(:file, kind, [fd])
          end),
          0
        )
      end

    :file.close(fd)
    File.rm!(path)
    summarize(samples)
  end

  defp empty_sync(dir, iters) do
    {name, _path} = log = open_log(dir)
    :ok = :disk_log.log(name, Bench.Payload.commit_of_size(200))
    :ok = :disk_log.sync(name)
    samples = for _ <- 1..iters//1, do: elem(time(fn -> :ok = :disk_log.sync(name) end), 0)
    close_log(log)
    summarize(samples)
  end

  defp encode(iters) do
    for {label, target} <- @sizes do
      commit = Bench.Payload.commit_of_size(target)
      n = if target >= 1_048_576, do: max(20, div(iters, 10)), else: iters
      etf = for _ <- 1..n//1, do: elem(time(fn -> :erlang.term_to_binary(commit) end), 0)
      json = for _ <- 1..n//1, do: elem(time(fn -> JSON.encode!(commit) end), 0)

      %{
        label: label,
        iters: n,
        etf_bytes: :erlang.external_size(commit),
        json_bytes: byte_size(JSON.encode!(commit)),
        term_to_binary: summarize(etf),
        json_encode: summarize(json)
      }
    end
  end
end

defmodule Bench.Workload do
  @moduledoc false
  # The synthetic session shape shared by B1 and B2: each turn starts, then
  # cycles assistant(tool call) -> tool_started -> tool result until the turn
  # has `turn_commits` commits, then settles.
  alias Tackle.Lib.Message

  def assistant(i, bytes) do
    Message.assistant(
      content: Bench.Text.of_size(bytes, i),
      tool_calls: [%{id: "call-#{i}", name: "bench_noop", arguments: %{"i" => i}}],
      model: "bench/fake",
      id_generator: fn -> "a-#{i}" end
    )
  end

  def user(t, bytes),
    do: Message.user(Bench.Text.of_size(bytes, t + 5), id_generator: fn -> "u-#{t}" end)

  def tool_call(i), do: %{id: "call-#{i}", name: "bench_noop", arguments: %{"i" => i}}

  def tool_result(i, bytes),
    do:
      Message.tool_result("call-#{i}", "bench_noop", Bench.Text.of_size(bytes, i + 3),
        id_generator: fn -> "t-#{i}" end
      )

  @doc """
  Returns the planned operation list, one per commit, `commits` long:
  `{:begin, t}`, `{:user, t}`, then whole `{:assistant, i}`, `{:tool_started, i}`,
  `{:tool_result, i}` cycles, and `{:settle, t}` once the turn has reached
  `turn_commits` at a cycle boundary.
  """
  def plan(commits, turn_commits) do
    Stream.unfold({1, 0, 0, 0}, fn
      {seq, _in_turn, _i, _t} when seq > commits ->
        nil

      {seq, 0, i, t} ->
        {{:begin, t}, {seq + 1, 1, i, t}}

      {seq, 1, i, t} ->
        {{:user, t}, {seq + 1, 2, i, t}}

      {seq, in_turn, i, t} when in_turn >= turn_commits - 1 and rem(i, 3) == 0 ->
        {{:settle, t}, {seq + 1, 0, i, t + 1}}

      {seq, in_turn, i, t} ->
        op =
          case rem(i, 3) do
            0 -> {:assistant, div(i, 3)}
            1 -> {:tool_started, div(i, 3)}
            2 -> {:tool_result, div(i, 3)}
          end

        {op, {seq + 1, in_turn + 1, i + 1, t}}
    end)
    |> Enum.to_list()
  end

  def op_name({op, _i}), do: op
end

defmodule Bench.JournalAPI do
  @moduledoc false
  # B1: a real journal owner, its watchdog, disk_log, and the live Catalog.
  import Bench.Stats, only: [time: 1, summarize: 1]
  alias Tackle.Session.Journal
  alias Bench.Workload

  def run(knobs, home, commits) do
    session_id = Tackle.Runtime.ID.generate()

    {:ok, journal} =
      Journal.start_link(
        session_id: session_id,
        home: home,
        tree: true,
        model_ref: "bench/fake"
      )

    # The first begin_turn materializes the journal (lock, open, header, created).
    plan = Workload.plan(commits, knobs.turn_commits)
    {first_us, {:ok, _}} = time(fn -> Journal.begin_turn(journal, :run, "bench") end)
    {:ok, %{last_seq: base_seq}} = Journal.status(journal)

    {samples, _parent} =
      plan
      |> Enum.drop(1)
      |> Enum.with_index(base_seq + 1)
      |> Enum.map_reduce("none", fn {op, seq}, parent ->
        {us, parent} = run_op(journal, op, parent, knobs.msg_bytes)
        {%{op: Workload.op_name(op), seq: seq, us: us}, parent}
      end)

    {:ok, status} = Journal.status(journal)

    flush =
      for _ <- 1..knobs.flush_samples//1,
          do: elem(time(fn -> :ok = Journal.flush(journal) end), 0)

    status_rt =
      for _ <- 1..knobs.flush_samples//1,
          do: elem(time(fn -> {:ok, _} = Journal.status(journal) end), 0)

    {close_us, :ok} = time(fn -> GenServer.stop(journal, :normal, 60_000) end)

    windows =
      windows(samples, Enum.filter(knobs.checkpoints, &(&1 <= status.last_seq)), knobs.window)

    %{
      commits: status.last_seq,
      first_begin_turn_us: first_us,
      close_us: close_us,
      ops: by_op(samples),
      all: summarize(Enum.map(samples, & &1.us)),
      windows: windows,
      flush: summarize(flush),
      status_roundtrip: summarize(status_rt)
    }
  end

  defp run_op(journal, {:user, t}, parent, bytes) do
    message = Workload.user(t, bytes)
    {us, :ok} = time(fn -> Journal.append_message(journal, message, tree_parent(parent)) end)
    {us, message.id}
  end

  defp run_op(journal, {:begin, _t}, parent, _bytes) do
    {us, {:ok, _}} = time(fn -> Journal.begin_turn(journal, :run, "bench") end)
    {us, parent}
  end

  defp run_op(journal, {:settle, _t}, parent, _bytes) do
    {us, :ok} = time(fn -> Journal.settle_turn(journal, "turn.completed", %{}) end)
    {us, parent}
  end

  defp run_op(journal, {:assistant, i}, parent, bytes) do
    message = Workload.assistant(i, bytes)
    {us, :ok} = time(fn -> Journal.append_message(journal, message, tree_parent(parent)) end)
    {us, message.id}
  end

  defp run_op(journal, {:tool_started, i}, parent, _bytes) do
    {us, :ok} = time(fn -> Journal.tool_started(journal, Workload.tool_call(i)) end)
    {us, parent}
  end

  defp run_op(journal, {:tool_result, i}, parent, bytes) do
    message = Workload.tool_result(i, bytes)
    {us, :ok} = time(fn -> Journal.append_message(journal, message, tree_parent(parent)) end)
    {us, message.id}
  end

  defp tree_parent("none"), do: {:tree, nil}
  defp tree_parent(id), do: {:tree, id}

  def by_op(samples) do
    samples
    |> Enum.group_by(& &1.op, & &1.us)
    |> Map.new(fn {op, values} -> {op, summarize(values)} end)
  end

  def windows(samples, checkpoints, width) do
    for checkpoint <- checkpoints do
      low = max(1, checkpoint - div(width, 2))
      high = low + width - 1
      in_window = Enum.filter(samples, &(&1.seq >= low and &1.seq <= high))

      %{
        checkpoint: checkpoint,
        from: low,
        to: min(high, samples |> Enum.map(& &1.seq) |> Enum.max(fn -> high end)),
        all: summarize(Enum.map(in_window, & &1.us)),
        ops: by_op(in_window)
      }
    end
  end
end

defmodule Bench.Stages do
  @moduledoc false
  # B2: the journal's commit pipeline, replicated from public pieces, without
  # the disk. Stages run in the same order on a growing projection, including
  # the Catalog.record cast to the live Catalog, so their cost at commit #n
  # matches what the journal owner pays at #n.
  import Bench.Stats, only: [time: 1, summarize: 1]
  alias Bench.Workload
  alias Tackle.Session.Catalog
  alias Tackle.Session.Codec
  alias Tackle.Session.Log
  alias Tackle.Session.Projection

  @stages [:event, :envelope, :validate, :term_to_binary, :projection, :summary, :catalog]

  def stages, do: @stages

  def run(knobs) do
    session_id = "bench-stages-" <> Tackle.Runtime.ID.generate()
    now = now()
    header = Log.header(session_id: session_id, created_at: now, cwd: nil, parent: nil)

    created =
      Log.event("session.created", %{
        "cwd" => nil,
        "model_ref" => "bench/fake",
        "thinking" => nil,
        "title" => nil,
        "tags" => [],
        "tree" => true
      })

    state = %{
      session_id: session_id,
      projection: Projection.new(header),
      next_seq: 1,
      active?: false,
      turn_id: nil,
      parent: nil
    }

    {state, first} = commit(state, fn _state -> created end)
    plan = Workload.plan(knobs.commits, knobs.turn_commits)

    {samples, _state} =
      Enum.map_reduce(plan, state, fn op, state ->
        {state, timings} = step(state, op, knobs.msg_bytes)
        {Map.merge(timings, %{op: Workload.op_name(op), seq: state.next_seq - 1}), state}
      end)

    samples = [Map.merge(first, %{op: :created, seq: 1}) | samples]
    checkpoints = Enum.filter(knobs.checkpoints, &(&1 <= knobs.commits))

    %{
      commits: length(samples),
      overall: per_stage(samples),
      windows:
        for checkpoint <- checkpoints do
          low = max(1, checkpoint - div(knobs.window, 2))
          high = low + knobs.window - 1
          in_window = Enum.filter(samples, &(&1.seq >= low and &1.seq <= high))

          %{
            checkpoint: checkpoint,
            from: low,
            to: high,
            stages: per_stage(in_window),
            ops:
              in_window
              |> Enum.group_by(& &1.op)
              |> Map.new(fn {op, op_samples} -> {op, per_stage(op_samples)} end)
          }
        end,
      commit_bytes: commit_bytes(samples)
    }
  end

  defp per_stage(samples) do
    totals = Enum.map(samples, fn s -> Enum.sum(Enum.map(@stages, &Map.fetch!(s, &1))) end)

    @stages
    |> Map.new(fn stage -> {stage, summarize(Enum.map(samples, &Map.fetch!(&1, stage)))} end)
    |> Map.put(:total, summarize(totals))
  end

  defp commit_bytes(samples) do
    samples
    |> Enum.group_by(& &1.op, & &1.bytes)
    |> Map.new(fn {op, sizes} -> {op, Enum.sum(sizes) / length(sizes)} end)
  end

  defp step(state, {:begin, _t}, _bytes) do
    turn_id = Tackle.Runtime.ID.generate()
    state = %{state | turn_id: turn_id, active?: true}

    commit(state, fn _state ->
      Log.event("turn.started", %{
        "turn_id" => turn_id,
        "operation" => "run",
        "input" => "bench",
        "started_at" => now()
      })
    end)
  end

  defp step(state, {:settle, _t}, _bytes) do
    {state, timings} =
      commit(state, fn state ->
        payload = %{"turn_id" => state.turn_id, "settled_at" => now()}
        :ok = Codec.validate(payload)
        Log.event("turn.completed", payload)
      end)

    {%{state | active?: false}, timings}
  end

  defp step(state, {:user, t}, bytes),
    do: message_step(state, Workload.user(t, bytes))

  defp step(state, {:assistant, i}, bytes),
    do: message_step(state, Workload.assistant(i, bytes))

  defp step(state, {:tool_result, i}, bytes),
    do: message_step(state, Workload.tool_result(i, bytes))

  defp step(state, {:tool_started, i}, _bytes) do
    commit(state, fn _state ->
      call = Codec.normalize(Workload.tool_call(i))

      data = %{
        "tool_call_id" => Map.get(call, "id"),
        "name" => Map.get(call, "name"),
        "arguments" => Map.get(call, "arguments") || %{},
        "started_at" => now()
      }

      :ok = Codec.validate(data)
      Log.event("tool.execution_started", data)
    end)
  end

  defp message_step(state, message) do
    {state, timings} =
      commit(state, fn state ->
        {:ok, data} = Codec.encode_message(message)
        Log.event("message.appended", Map.put(data_wrap(data), "parent_id", state.parent))
      end)

    {%{state | parent: message.id}, timings}
  end

  defp data_wrap(data), do: %{"message" => data}

  # Mirrors Tackle.Session.Journal.commit/3 minus the disk_log append and sync.
  defp commit(state, event_fun) do
    seq = state.next_seq
    {event_us, event} = time(fn -> event_fun.(state) end)

    {envelope_us, commit} =
      time(fn ->
        Log.commit(
          session_id: state.session_id,
          seq: seq,
          commit_id: Tackle.Runtime.ID.generate(),
          written_at: now(),
          turn_id: state.turn_id,
          events: [event]
        )
      end)

    {validate_us, :ok} =
      time(fn ->
        with :ok <- Log.validate_commit(commit, state.session_id, seq), do: Codec.validate(commit)
      end)

    {etf_us, etf} = time(fn -> :erlang.term_to_binary(commit) end)

    {projection_us, projection} =
      time(fn -> Projection.apply_commit(state.projection, commit) end)

    next = %{state | projection: projection, next_seq: seq + 1}
    {summary_us, summary} = time(fn -> build_summary(next) end)
    {catalog_us, :ok} = time(fn -> Catalog.record(summary) end)

    {next,
     %{
       event: event_us,
       envelope: envelope_us,
       validate: validate_us,
       term_to_binary: etf_us,
       projection: projection_us,
       summary: summary_us,
       catalog: catalog_us,
       bytes: byte_size(etf)
     }}
  end

  # Mirrors the journal's private build_summary/1.
  defp build_summary(state) do
    status = if state.active?, do: :active, else: state.projection.status

    state.projection
    |> Map.put(:status, status)
    |> Projection.metadata()
  end

  defp now, do: DateTime.to_iso8601(DateTime.utc_now())
end

defmodule Bench.E2E do
  @moduledoc false
  import Bench.Stats, only: [time: 1, summarize: 1]
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.Limits
  alias Tackle.Runtime.ScopeSpec
  alias Tackle.Session.Journal

  def scenarios(knobs) do
    [
      %{name: "answer only (N=0)", iterations: 0, calls: 1},
      %{name: "sequential (N=#{knobs.e2e_iters}, K=1)", iterations: knobs.e2e_iters, calls: 1},
      %{
        name: "sequential read-only (N=#{knobs.e2e_iters}, K=1)",
        iterations: knobs.e2e_iters,
        calls: 1,
        tool: Bench.ReadOnlyTool
      },
      %{
        name: "parallel (N=#{knobs.e2e_iters}, K=#{knobs.e2e_parallel})",
        iterations: knobs.e2e_iters,
        calls: knobs.e2e_parallel
      }
    ]
  end

  def run(knobs, home) do
    :persistent_term.put({Bench, :tool_payload}, Bench.Text.of_size(knobs.e2e_payload))

    for scenario <- scenarios(knobs) do
      ephemeral = run_mode(knobs, home, scenario, :ephemeral)
      durable = run_mode(knobs, home, scenario, :durable)
      Map.merge(scenario, %{ephemeral: ephemeral, durable: durable})
    end
  end

  defp run_mode(knobs, home, scenario, mode) do
    {:ok, config} =
      Tackle.Config.new(
        providers: [Bench.FakeLLM],
        model: "bench/fake",
        tools: [Map.get(scenario, :tool, Bench.NoopTool)],
        system_prompt: "Benchmark agent.",
        # Default :infinity. A finite limit is not usable here: Loop.run/3
        # (submit) does not reset current_iteration, so it accumulates across
        # turns of one session. The fake model always terminates.
        llm_opts: [bench_iterations: scenario.iterations, bench_tool_calls: scenario.calls]
      )

    agent =
      AgentSpec.new!(name: "root", config: config, allow_delegation: false, timeout: 600_000)

    session =
      if mode == :durable, do: Tackle.Session.Spec.new!(storage: [home: home]), else: nil

    {:ok, scope} =
      Tackle.Runtime.start_scope(
        ScopeSpec.new!(
          root_spec: agent,
          limits: Limits.default(),
          profiles: %{},
          session: session
        )
      )

    try do
      {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
      for _ <- 1..knobs.e2e_warmup//1, do: run_turn(scope.root_agent_ref)
      seq_before = last_seq(snapshot.session_id)
      bytes_before = journal_bytes(snapshot.session_id, home)
      device_before = device_bytes_written(home)
      counter = start_sync_counter(snapshot.session_id)
      turns = for _ <- 1..knobs.e2e_turns//1, do: run_turn(scope.root_agent_ref)
      seq_after = last_seq(snapshot.session_id)
      syncs = sync_count(counter)
      # Write-behind commits may still sit in :disk_log's cache or the OS page
      # cache. Flush once (after the sync count) so the file size and the
      # device counter include that deferred writeback, amortized over the turns.
      flush_journal(snapshot.session_id)
      bytes_after = journal_bytes(snapshot.session_id, home)
      device_after = device_bytes_written(home)
      per_turn = fn total -> total / max(knobs.e2e_turns, 1) end

      %{
        turn: summarize(turns),
        commits_per_turn: if(seq_before, do: per_turn.(seq_after - seq_before), else: 0),
        syncs_per_turn: per_turn.(syncs),
        bytes_per_turn: if(bytes_before, do: per_turn.(bytes_after - bytes_before), else: 0),
        device_bytes_per_turn:
          if(device_before && device_after, do: per_turn.(device_after - device_before))
      }
    after
      Tackle.Runtime.stop_scope(scope.scope_ref)
      drain()
    end
  end

  defp run_turn(agent_ref) do
    {us, :ok} =
      time(fn ->
        {:ok, turn_id} = Tackle.submit(agent_ref, "go")
        await(turn_id)
      end)

    drain()
    us
  end

  defp await(turn_id) do
    receive do
      {:tackle_turn_finished, _session_id, ^turn_id, {:ok, _state}} ->
        :ok

      {:tackle_turn_finished, _session_id, ^turn_id, other} ->
        raise "turn failed: #{inspect(other, limit: 5)}"

      {:tackle_turn_failed, _session_id, ^turn_id, reason} ->
        raise "turn failed: #{inspect(reason, limit: 5)}"

      {:EXIT, _pid, reason} when reason not in [:normal, :shutdown] ->
        raise "linked process exited: #{inspect(reason, limit: 5)}"

      _event ->
        await(turn_id)
    after
      120_000 -> raise "turn #{turn_id} timed out"
    end
  end

  # Counts the journal owner's real `Reader.sync/1` calls (each one fsync) with
  # a separate tracer process, so draining the bench mailbox cannot drop them.
  defp start_sync_counter(session_id) do
    case Journal.whereis(session_id) do
      {:ok, journal} ->
        counter = spawn(fn -> count_syncs(0) end)
        :erlang.trace_pattern({Tackle.Session.Reader, :sync, 1}, true, [:global])
        1 = :erlang.trace(journal, true, [:call, {:tracer, counter}])
        {journal, counter}

      {:error, :not_found} ->
        nil
    end
  end

  defp sync_count(nil), do: 0

  defp sync_count({journal, counter}) do
    # A round trip to the owner orders its earlier trace messages before ours.
    {:ok, _status} = Journal.status(journal)
    :erlang.trace(journal, false, [:call])
    :erlang.trace_pattern({Tackle.Session.Reader, :sync, 1}, false, [:global])
    Process.sleep(20)
    send(counter, {:count, self()})

    receive do
      {:sync_count, count} -> count
    after
      5_000 -> raise "sync counter did not answer"
    end
  end

  defp count_syncs(count) do
    receive do
      {:trace, _pid, :call, {Tackle.Session.Reader, :sync, _args}} -> count_syncs(count + 1)
      {:count, from} -> send(from, {:sync_count, count})
    end
  end

  # Bytes the block device holding `dir` reported as written (Linux
  # /proc/diskstats). System-wide for that device, so other activity adds noise,
  # but it includes filesystem journal and metadata writes caused by each fsync.
  defp device_bytes_written(dir) do
    with {out, 0} <- System.cmd("df", ["--output=source", dir], stderr_to_stdout: true),
         [_header, source | _rest] <- String.split(out, "\n", trim: true),
         device = Path.basename(String.trim(source)),
         {:ok, stats} <- File.read("/proc/diskstats"),
         [sectors] <-
           for(
             line <- String.split(stats, "\n", trim: true),
             [_major, _minor, ^device | fields] <- [String.split(line)],
             do: Enum.at(fields, 6)
           ) do
      String.to_integer(sectors) * 512
    else
      _other -> nil
    end
  rescue
    _error -> nil
  end

  defp flush_journal(session_id) do
    case Journal.whereis(session_id) do
      {:ok, journal} -> :ok = Journal.flush(journal)
      {:error, :not_found} -> :ok
    end
  end

  defp journal_bytes(session_id, home) do
    with {:ok, path} <- Tackle.Session.Storage.journal_path(session_id, home: home),
         {:ok, %File.Stat{size: size}} <- File.stat(path) do
      size
    else
      _other -> nil
    end
  end

  defp last_seq(session_id) do
    case Journal.whereis(session_id) do
      {:ok, journal} ->
        {:ok, %{last_seq: seq}} = Journal.status(journal)
        seq

      {:error, :not_found} ->
        nil
    end
  end

  defp drain do
    receive do
      _message -> drain()
    after
      0 -> :ok
    end
  end
end

defmodule Bench.Machine do
  @moduledoc false

  def info(knobs, data_dir) do
    %{
      git: git(knobs.package),
      hostname: hostname(),
      uname: cmd("uname", ["-srmo"]),
      cpu: cpu_model(),
      logical_cpus: :erlang.system_info(:logical_processors_available),
      schedulers: :erlang.system_info(:schedulers_online),
      dirty_io_schedulers: :erlang.system_info(:dirty_io_schedulers),
      mem_total: mem_total(),
      otp: List.to_string(:erlang.system_info(:otp_release)),
      erts: List.to_string(:erlang.system_info(:version)),
      elixir: System.version(),
      data_dir: data_dir,
      df: cmd("df", ["-T", data_dir]),
      mount: cmd("findmnt", ["-no", "SOURCE,FSTYPE,OPTIONS", "-T", data_dir])
    }
  end

  defp git(package) do
    sha = cmd("git", ["-C", package, "rev-parse", "HEAD"])

    paths = ["lib", "../tackle_lib/lib", "../tackle_runtime/lib"]
    status = cmd("git", ["-C", package, "status", "--porcelain", "--" | paths])
    diff = cmd("git", ["-C", package, "diff", "HEAD", "--" | paths])

    %{
      sha: sha,
      lib_dirty: status not in [nil, ""],
      lib_status: status,
      lib_diff_sha256:
        if(diff in [nil, ""],
          do: nil,
          else: Base.encode16(:crypto.hash(:sha256, diff), case: :lower)
        )
    }
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> List.to_string(name)
      _error -> nil
    end
  end

  defp cpu_model do
    case File.read("/proc/cpuinfo") do
      {:ok, text} ->
        text
        |> String.split("\n")
        |> Enum.find_value(fn line ->
          case String.split(line, ":", parts: 2) do
            [key, value] -> if String.trim(key) == "model name", do: String.trim(value)
            _other -> nil
          end
        end)

      _error ->
        nil
    end
  end

  defp mem_total do
    case File.read("/proc/meminfo") do
      {:ok, "MemTotal:" <> rest} -> rest |> String.split("\n") |> hd() |> String.trim()
      _other -> nil
    end
  end

  defp cmd(name, args) do
    case System.find_executable(name) do
      nil ->
        nil

      path ->
        case System.cmd(path, args, stderr_to_stdout: true) do
          {out, 0} -> String.trim(out)
          {out, _status} -> "error: " <> String.trim(out)
        end
    end
  rescue
    _error -> nil
  end
end

defmodule Bench.Report do
  @moduledoc false
  import Bench.Stats

  def header(results) do
    m = results.machine
    k = results.knobs
    git = m.git

    """
    # Session journal benchmark

    Synthetic baseline — fake LLM and no-op tools; see the script header.

    - date: #{results.started_at}
    - git: `#{git.sha}`#{if git.lib_dirty, do: " (lib/ has uncommitted changes, diff sha256 #{String.slice(git.lib_diff_sha256 || "", 0, 12)})", else: " (lib/ clean)"}
    - host: #{m.hostname} — #{m.uname}
    - cpu: #{m.cpu} (#{m.logical_cpus} logical, #{m.schedulers} schedulers, #{m.dirty_io_schedulers} dirty IO)
    - memory: #{m.mem_total}
    - OTP #{m.otp} (erts #{m.erts}), Elixir #{m.elixir}
    - data dir: `#{m.data_dir}`
    - mount: `#{m.mount}`
    - knobs: commits=#{k.commits} msg_bytes=#{k.msg_bytes} turn_commits=#{k.turn_commits} raw_iters=#{k.raw_iters} e2e_turns=#{k.e2e_turns} N=#{k.e2e_iters} K=#{k.e2e_parallel} contention=#{Enum.join(k.contention, ",")} (writers=#{k.contention_writers} chunk=#{k.contention_chunk_mb} MiB cap=#{k.contention_mbps} MiB/s, B1 commits=#{k.contention_commits})

    ```
    #{m.df}
    ```
    """
  end

  def raw(raw) do
    rows =
      for s <- raw.sizes do
        [
          s.label,
          bytes(s.etf_bytes),
          Integer.to_string(s.iters),
          fmt(s.log_only.p50),
          fmt(s.log_only.p99),
          fmt(s.log_sync.total.p50),
          fmt(s.log_sync.total.p95),
          fmt(s.log_sync.total.p99),
          fmt(s.log_sync.total.max),
          fmt(s.log_sync.sync.p50),
          fmt(s.raw_fsync.p50),
          fmt(s.raw_fdatasync.p50)
        ]
      end

    encode_rows =
      for e <- raw.encode do
        [
          e.label,
          bytes(e.etf_bytes),
          bytes(e.json_bytes),
          fmt(e.term_to_binary.p50),
          fmt(e.term_to_binary.p99),
          fmt(e.json_encode.p50),
          fmt(e.json_encode.p99),
          num(e.json_encode.p50 / max(e.term_to_binary.p50, 0.001)) <> "×"
        ]
      end

    """
    ## A. Raw floor (quiet disk)

    Per commit. `log+sync` is what the journal does per commit; `sync` is its
    fsync part. disk_log buffers up to 64 KiB before writing, so `log-only` is
    mostly an in-memory call below that size. Raw columns are `:file.write`
    followed by fsync or fdatasync on a raw append fd, for reference.

    #{table(["payload", "ETF", "n", "log-only p50", "log-only p99", "log+sync p50", "p95", "p99", "max", "sync p50", "raw write+fsync p50", "raw write+fdatasync p50"], rows)}

    disk_log sync with nothing pending (provider-gate flush floor): #{stat_line(raw.empty_sync)}

    Encoding the same commit envelope:

    #{table(["payload", "ETF size", "JSON size", "term_to_binary p50", "p99", "JSON.encode! p50", "p99", "JSON/ETF"], encode_rows)}
    """
  end

  def quick_sync(rows) do
    body =
      for r <- rows do
        [r.label] ++ stat_cells(r.log_sync.total) ++ [fmt(r.log_sync.sync.p50)]
      end

    table(["payload"] ++ stat_header() ++ ["sync p50"], body)
  end

  def journal(b1, label) do
    op_rows =
      for op <- [:begin, :user, :assistant, :tool_started, :tool_result, :settle],
          Map.has_key?(b1.ops, op) do
        s = Map.fetch!(b1.ops, op)
        [op_label(op)] ++ stat_cells(s) ++ [fmt(s.total)]
      end

    window_rows =
      for w <- b1.windows do
        per_op =
          Enum.map([:assistant, :tool_result, :tool_started], fn op ->
            case Map.get(w.ops, op) do
              %{p50: p50} -> fmt(p50)
              _missing -> "—"
            end
          end)

        ["##{w.checkpoint} (#{w.from}–#{w.to})"] ++ stat_cells(w.all) ++ per_op
      end

    """
    ### B1. Journal API — #{label}

    Real `Tackle.Session.Journal` owner (+ watchdog, disk_log, live Catalog);
    #{b1.commits} commits; message content = BENCH_MSG_BYTES. First
    begin_turn (materializes the journal): #{fmt(b1.first_begin_turn_us)}; close: #{fmt(b1.close_us)}.

    #{table(["operation"] ++ stat_header() ++ ["total"], op_rows ++ [["**all commits**"] ++ stat_cells(b1.all) ++ [fmt(b1.all.total)]])}

    By session length (stats over all ops in the window, then per-op p50):

    #{table(["commit window"] ++ stat_header() ++ ["assistant p50", "tool result p50", "tool_started p50"], window_rows)}

    - `flush` (provider gate, nothing pending): #{stat_line(b1.flush)}
    - `status` round trip (plain GenServer.call, no watchdog, no disk): #{stat_line(b1.status_roundtrip)}
    """
  end

  def stages(b2, raw_log_sync_p50) do
    stage_names = Bench.Stages.stages() ++ [:total]

    rows =
      for w <- b2.windows do
        ["##{w.checkpoint} (#{w.from}–#{w.to})"] ++
          Enum.map(stage_names, fn stage -> p50_p99(w.stages[stage]) end)
      end

    overall = ["all #{b2.commits}"] ++ Enum.map(stage_names, &p50_p99(b2.overall[&1]))

    op_rows =
      for w <- b2.windows, op <- [:assistant, :tool_result, :tool_started], w.ops[op] do
        ["##{w.checkpoint}", op_label(op)] ++
          Enum.map(stage_names, fn stage -> fmt(w.ops[op][stage].p50) end)
      end

    bytes_line =
      b2.commit_bytes
      |> Enum.sort()
      |> Enum.map_join(", ", fn {op, b} -> "#{op_label(op)} #{bytes(b)}" end)

    """
    ### B2. Commit stages in-process (no disk), p50 / p99

    `event` = message/tool/turn event encoding (Codec.encode_message or
    Codec.validate of tool/settle data), `envelope` = Log.commit, `validate` =
    Log.validate_commit + Codec.validate of the whole commit, `term_to_binary` =
    the encoding `:disk_log.log/2` performs in the journal process, `projection`
    = Projection.apply_commit, `summary` = the private build_summary/1 rebuilt
    from Projection.metadata/1, `catalog` = Catalog.record/1
    (a cast). Disk append+sync come on top (A: ~#{fmt(raw_log_sync_p50)} p50 for 4 KB).

    #{table(["commit window" | Enum.map(stage_names, &to_string/1)], rows ++ [overall])}

    Per operation, p50:

    #{table(["window", "operation" | Enum.map(stage_names, &to_string/1)], op_rows)}

    Mean ETF bytes per commit: #{bytes_line}.
    """
  end

  def residual(b1, b2, raw) do
    empty_sync = raw.empty_sync.p50
    log_sync = Enum.map_join(raw.sizes, ", ", &"#{&1.label} #{fmt(&1.log_sync.total.p50)}")

    rows =
      for w <- b1.windows,
          w2 <- Enum.filter(b2.windows, &(&1.checkpoint == w.checkpoint)) do
        api = w.all.p50
        cpu = w2.stages.total.p50

        ["##{w.checkpoint}", fmt(api), fmt(cpu), fmt(api - cpu), num(cpu / api * 100) <> " %"]
      end

    """
    #{table(["commit window", "API p50", "in-process stages p50", "API − stages (disk + hops)", "stages share"], rows)}

    Same-run references: disk_log log+sync p50 #{log_sync}. Watchdog hop
    estimate: B1 flush p50 #{fmt(b1.flush.p50)} − raw empty sync p50
    #{fmt(empty_sync)} = #{fmt(b1.flush.p50 - empty_sync)} (fsync jitter between
    runs is of the same order, so treat small or negative values as ≈ 0).
    """
  end

  def e2e(rows, b1, label) do
    commit_p50 = b1.all.p50
    flush_p50 = b1.flush.p50

    turn_rows =
      for r <- rows, mode <- [:ephemeral, :durable] do
        s = Map.fetch!(r, mode).turn
        [r.name, to_string(mode)] ++ stat_cells(s)
      end

    overhead_rows =
      for r <- rows do
        provider_calls = r.iterations + 1
        commits = r.durable.commits_per_turn
        fsyncs = r.durable.syncs_per_turn
        delta_p50 = r.durable.turn.p50 - r.ephemeral.turn.p50
        delta_mean = r.durable.turn.mean - r.ephemeral.turn.mean
        serial = commits * commit_p50 + provider_calls * flush_p50

        [
          r.name,
          num(commits),
          num(fsyncs),
          bytes(r.durable.bytes_per_turn),
          if(r.durable.device_bytes_per_turn,
            do: bytes(r.durable.device_bytes_per_turn),
            else: "n/a"
          ),
          fmt(delta_p50),
          fmt(delta_mean),
          fmt(delta_p50 / provider_calls),
          fmt(delta_p50 / max(commits, 1)),
          fmt(serial),
          num(delta_p50 / max(serial, 1)) <> "×"
        ]
      end

    """
    ### C. End-to-end ReAct turn — #{label}

    #{table(["scenario", "mode"] ++ stat_header(), turn_rows)}

    Durable − ephemeral. `fsyncs` = journal syncs actually issued per turn
    (traced `Reader.sync/1` calls). `journal bytes` = journal file growth per
    turn. `device writes` = bytes the underlying block device wrote per turn,
    including one closing flush of the session amortized over the turns
    (/proc/diskstats; system-wide, so noisy, but it includes the filesystem
    journal and metadata writes each fsync causes — the drive-wear number). `serial est.` = commits × B1 commit p50 (#{fmt(commit_p50)}) +
    provider calls × B1 flush p50 (#{fmt(flush_p50)}): the overhead if every
    commit synced on its own and every provider call flushed, as before
    write-behind appends. A ratio near 1× means every commit is on the turn's
    critical path.

    #{table(["scenario", "commits/turn", "fsyncs/turn", "journal bytes/turn", "device writes/turn", "Δ p50/turn", "Δ mean/turn", "Δ/provider call", "Δ/commit", "serial est.", "Δ/serial"], overhead_rows)}
    """
  end

  def contention(stats) do
    lines =
      for {s, i} <- Enum.with_index(stats, 1) do
        if Map.has_key?(s, :error) do
          "- writer #{i}: #{s.error}"
        else
          "- writer #{i}: #{bytes(s.bytes)} in #{num(s.seconds)} s (#{num(s.mb_per_s)} MiB/s), #{s.syncs} fsyncs; its fsync #{stat_line(s.sync)}"
        end
      end

    Enum.join(lines, "\n")
  end

  def stat_line(%{n: 0}), do: "no samples"

  def stat_line(s),
    do: "p50 #{fmt(s.p50)}, p95 #{fmt(s.p95)}, p99 #{fmt(s.p99)}, max #{fmt(s.max)} (n=#{s.n})"

  defp p50_p99(nil), do: "—"
  defp p50_p99(%{n: 0}), do: "—"
  defp p50_p99(s), do: "#{fmt(s.p50)} / #{fmt(s.p99)}"

  defp op_label(:begin), do: "begin_turn"
  defp op_label(:user), do: "append_message (user)"
  defp op_label(:assistant), do: "append_message (assistant)"
  defp op_label(:tool_started), do: "tool_started"
  defp op_label(:tool_result), do: "append_message (tool result)"
  defp op_label(:settle), do: "settle_turn"
  defp op_label(:created), do: "session.created"
end

defmodule Bench.Main do
  @moduledoc false
  alias Bench.Report

  def run do
    knobs = Bench.Knobs.load()
    run_dir = Path.join(knobs.dir, "run-#{knobs.stamp}-#{System.unique_integer([:positive])}")
    home = Path.join(run_dir, "home")
    File.mkdir_p!(home)
    started = System.monotonic_time()

    try do
      start_app(home)
      Process.flag(:trap_exit, true)
      results = measure(knobs, run_dir, home)
      seconds = Bench.Stats.us(System.monotonic_time() - started) / 1_000_000
      results = Map.put(results, :wall_seconds, seconds)
      IO.puts("\n_Total wall time: #{Bench.Stats.num(seconds)} s_\n")
      write_json(knobs.out, results)
      IO.puts("JSON results: #{knobs.out}")
    after
      cleanup(knobs, run_dir)
    end
  end

  defp start_app(home) do
    if List.keymember?(Application.started_applications(), :tackle, 0) do
      :ok = Application.stop(:tackle)
    end

    System.put_env("TACKLE_HOME", home)
    Application.put_env(:tackle, :auth_file, Path.join(home, "auth.json"))
    Logger.configure(level: :warning)
    {:ok, _apps} = Application.ensure_all_started(:tackle)
  end

  defp measure(knobs, run_dir, home) do
    machine = Bench.Machine.info(knobs, run_dir)

    results = %{
      schema: "tackle.bench.session_journal/1",
      started_at: DateTime.to_iso8601(DateTime.utc_now()),
      knobs: Map.drop(knobs, [:package]),
      machine: machine
    }

    IO.puts(Report.header(results))

    raw = Bench.Raw.run(knobs, Path.join(run_dir, "raw"))
    IO.puts(Report.raw(raw))

    stages = Bench.Stages.run(knobs)

    modes =
      Map.new(knobs.contention, fn mode ->
        {mode, run_mode(mode, knobs, run_dir, home, stages, raw)}
      end)

    Map.merge(results, %{raw: raw, stages: stages, modes: modes})
  end

  defp run_mode(mode, knobs, run_dir, home, stages, raw) do
    IO.puts("## #{if mode == :quiet, do: "Quiet disk", else: "Under contention"}\n")

    writers =
      if mode == :contended do
        pids =
          Bench.Contention.start(
            Path.join(run_dir, "contention"),
            knobs.contention_writers,
            knobs.contention_chunk_mb,
            knobs.contention_file_mb,
            knobs.contention_mbps
          )

        # Let the writers build dirty-page pressure before measuring.
        Process.sleep(1_000)
        pids
      else
        []
      end

    commits =
      if mode == :contended, do: min(knobs.commits, knobs.contention_commits), else: knobs.commits

    try do
      quick =
        if mode == :contended do
          rows = Bench.Raw.quick_sync(Path.join(run_dir, "raw-contended"), 100)

          IO.puts(
            "### A′. disk_log log+sync under contention\n\n" <> Report.quick_sync(rows) <> "\n"
          )

          rows
        end

      b1 = Bench.JournalAPI.run(knobs, home, commits)
      IO.puts(Report.journal(b1, to_string(mode)))

      if mode == :quiet or knobs.contention == [:contended] do
        raw4k = Enum.find(raw.sizes, &(&1.target == 4096)).log_sync.total.p50
        IO.puts(Report.stages(stages, raw4k))
        IO.puts("Per-commit decomposition (B1 vs B2):\n")
        IO.puts(Report.residual(b1, stages, raw))
      end

      e2e = Bench.E2E.run(knobs, home)
      IO.puts(Report.e2e(e2e, b1, to_string(mode)))

      contention = Bench.Contention.stop(writers)

      if contention != [] do
        IO.puts("### Background writers\n\n" <> Report.contention(contention) <> "\n")
      end

      %{journal_api: b1, e2e: e2e, contention: contention, contended_raw: quick}
    after
      # Stop writers even if a measurement raised.
      Enum.each(writers, fn pid -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    end
  end

  defp write_json(path, results) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(jsonable(results)))
  end

  defp jsonable(%_{} = struct), do: struct |> Map.from_struct() |> jsonable()

  defp jsonable(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), jsonable(v)} end)

  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> jsonable()

  defp jsonable(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp jsonable(value), do: value

  defp cleanup(knobs, run_dir) do
    _ = Application.stop(:tackle)

    if knobs.keep? do
      IO.puts("Kept data directory: #{run_dir}")
    else
      File.rm_rf!(run_dir)
      # Only remove the default root when this run left it empty.
      if knobs.default_dir?, do: File.rmdir(knobs.dir)
    end
  end
end

Bench.Main.run()
