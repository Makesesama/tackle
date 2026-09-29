# Performance baselines

Benchee is a **dev-only, non-runtime dependency** of `tackle_lib` and
`tackle_runtime`. These repository-only scripts use synthetic data and a fake
runtime backend: no credentials, provider calls, network I/O, or paid services.
They do not change production behaviour and are not performance CI gates.

## Run

Use the configured development toolchain (`nix develop`, Elixir 1.20 / OTP 29).
From the repository root, fetch each project's dependencies once:

```sh
(cd packages/tackle_lib && mix deps.get)
(cd packages/tackle_runtime && mix deps.get)

(cd packages/tackle_lib && mix run bench/history.exs)
(cd packages/tackle_lib && mix run bench/context.exs)
(cd packages/tackle_lib && mix run bench/tools.exs)
(cd packages/tackle_runtime && mix run bench/lifecycle.exs)
(cd packages/tackle_runtime && mix run bench/workflow_start.exs)
(cd packages/tackle_runtime && mix run bench/retained.exs)
(cd packages/tackle_runtime && mix run bench/streaming.exs)
```

Run suites **serially** on an otherwise idle machine. They default to two seconds
of warmup and five seconds of timing per scenario/input. Library suites also
measure allocations and reductions for one second each. The full set takes
several minutes. For a quick correctness/smoke run, prefix each `mix run` with
`BENCH_SMOKE=1` (no warmup, 50 ms timing, no allocation/reduction measurements).
**Smoke timings are not baselines.** Assertions and Benchee pre-checks fail fast
on unexpected results; runtime fixture lifecycle/cleanup also has ExUnit coverage.

## Suites and measurement boundaries

| Script | Measures |
| --- | --- |
| `tackle_lib/bench/history.exs` | One append to existing linear/tree/shortened-projection histories; context estimation with/without a recent usage checkpoint; provider projection. 10–10,000 messages. Fixtures are built outside timing. |
| `tackle_lib/bench/context.exs` | Isolated context estimation with/without a recent checkpoint at 1,000–10,000 messages; allocations and reductions included. |
| `tackle_lib/bench/tools.exs` | Full echo-tool settlement with keyword or nested JSON Schema output validation, plus isolated JSV build/validate costs. 1–100 output items. |
| `tackle_runtime/bench/lifecycle.exs` | Full fresh-scope delegated lifecycle, plus one-child workflow start/await with untimed setup/cleanup. 10–10,000 returned messages. Also prints untimed retained Request process diagnostics. |
| `tackle_runtime/bench/streaming.exs` | Fresh scope → 0/100/1,000 event burst → awaited result → shutdown, with and without subscription. The unsubscribed backend produces no events. |
| `tackle_runtime/bench/workflow_start.exs` | Start → awaited one-child workflow with 1/100/500 pending agents in a pre-populated fleet. Per-sample setup, reservation and cleanup are excluded from timing. |
| `tackle_runtime/bench/retained.exs` | Untimed, post-GC retained Request and backend process bytes plus outcome/setup-config term words. Contrasts large results against large setup-only config. |

These are different workloads, not interchangeable implementations: cross-job
speed ratios are disabled. In particular, keyword validation only checks the
list/map shape; JSON Schema also checks nested properties. Precompiled JSV
validation omits the library's key normalization and schema build. The shortened
history fixture represents projection costs, not a real compaction transaction.
History append measures one append at a given size, not building an entire history.

Delegated runtime timings include scope startup, process/message copying, fake
backend work, and synchronous cleanup. Requests are monitored through normal
termination before stopping their scope to avoid measuring a shutdown race.
The workflow job instead times only start → awaited result; scope setup and
cleanup run in Benchee's untimed per-invocation hooks. Depending on when an
awaiter registers, workflows can linger **500 ms after completion**. The cleanup
hook waits for termination outside timing, so this scheduling-dependent retention
cannot masquerade as execution overhead (it still increases suite wall time and
reduces the number of samples collected; treat workflow p99 cautiously).
Each sample gets a fresh scope, avoiding asynchronously released
admission slots and accumulated results between iterations. Streaming includes
an atomic counter to verify every event was delivered, not UI rendering or a
production network stream. These suites do not yet measure peak mailbox depth, cancellation latency, or concurrent load.

Benchee memory/reduction metrics cover **only the benchmark process**, not
spawned workers, ETS, all binary storage, or the whole VM. They are disabled for
runtime timing suites. Instead, lifecycle prints JSON lines with the retained
Request's `memory` (bytes after a full GC), lifetime `reductions`, and current
`message_queue_len`, before collection. These are point-in-time diagnostics,
not peak memory, per-operation reductions, or total scope memory; the request
may also retain its spec/config until settlement. `bench/retained.exs` reports
separate backend process bytes and term sizes; these values cannot be added to
obtain whole-scope memory because terms can be shared and process memory includes
heap slack. The backend retains the configuration after settlement, while the
Request retains the full outcome for collection. Polling for completion affects
reductions. The synthetic runtime fixture deliberately contains unique small message strings,
so results should not be extrapolated to shared large binaries or real providers.

## Local before/after sample (synthetic)

Linux / Ryzen 9 7900X / Elixir 1.20.4 / OTP 29.0.6, serial full runs
with identical fixtures (saved under `/tmp/tackle-context-{before,after}.benchee`
and `/tmp/tackle-workflow-{before,after}.benchee`). These files are local,
not checked in. Values below are medians; p99 is susceptible to scheduling
noise. No-checkpoint profiling before editing (`mix profile.tprof --type memory`)
identified per-message `String.length/2` as the largest allocation source;
checkpoint list indexing also allocated. The refactor removes indexed copies
and the second message traversal but retains Unicode-aware `String.length/1`.

| Job / input | Before | After | Allocation before → after | Reductions before → after |
| --- | ---: | ---: | ---: | ---: |
| Context, recent checkpoint / 10k | 290 µs | 15.4 µs | 0.53 → 0.153 MB | 30.36k → 0.33k |
| Context, no checkpoint / 10k | 4.39 ms | 3.99 ms | 3.89 → 3.51 MB | 756.31k → 687.06k |
| Workflow start + await / 1 pending agent | 174.32 µs | 145.16 µs | — | — |
| Workflow start + await / 100 pending agents | 203.83 µs | 152.05 µs | — | — |
| Workflow start + await / 500 pending agents | 358.02 µs | 151.95 µs | — | — |

`bench/retained.exs` (untimed, after GC) reports a 10k-message Request
at 6,665,304 bytes and its backend at 2,546,592 bytes; outcome term size
270,201 words. Clearing setup-only Request fields did **not** lower Request
heap memory for this fixture: config and outcome reference the same history,
while the backend continues retaining configuration. A 10k-entry setup-only
blob with a small outcome yielded 13,880 Request bytes and 602,000 backend
bytes after settlement. These are diagnostics of separate processes/term
references, not additive scope totals or measured end-user gains. Full results
remain available until collected; bounded retention would need a separate
explicit lifecycle/API proposal.

## Save and compare

Benchee records machine/Elixir/OTP information in its output. Keep that output
alongside the Git revision and saved results. Save files are ignored by Git.
Choose a distinct file/tag for each suite and run:

```sh
cd packages/tackle_lib
BENCH_SAVE=context-before.benchee BENCH_TAG=before mix run bench/context.exs
# After a focused change, on the same machine/toolchain and with identical inputs:
BENCH_LOAD=context-before.benchee BENCH_SAVE=context-after.benchee \
  BENCH_TAG=after mix run bench/context.exs
```

Compare the same job/input across revisions: median, p99, allocation bytes, and
reductions. Repeat noisy results; retain GC/outliers rather than hiding them.
Only load trusted Benchee result files. Start with a baseline, profile a measured
hotspot (e.g. with the toolchain's `mix profile.tprof`), change one thing, rerun
correctness tests, then compare. Do not claim an end-user speedup from a
microbenchmark alone; provider/tool latency often dominates an agent turn.

Formatting benchmark-only scripts:

```sh
mix format bench/support.exs
(cd packages/tackle_lib && mix format 'bench/*.exs')
(cd packages/tackle_runtime && mix format 'bench/*.exs')
```
