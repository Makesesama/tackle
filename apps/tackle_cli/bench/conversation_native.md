# Conversation native rendering investigation

Run from `apps/tackle_cli`:

```sh
MIX_ENV=test mix run --no-start bench/conversation.exs
MIX_ENV=test mix run --no-start bench/conversation_native.exs
```

These are diagnostic probes, not performance gates. Five warmups and 40 timed
samples per case; p50/p95 are order statistics. Synthetic ~50 KB inputs, 80×24
viewport, no credentials. Keep fixtures/toolchain/build profile identical when
comparing changes. The stage script does not rebuild or force a native profile;
it uses the NIFs loaded by Mix, including ExRatatui's installed precompiled NIF.

## Measurement limits

`:timer.tc` includes synchronous native execution, dirty-scheduler waits, NIF
argument decoding and return-term encoding. It cannot distinguish those costs.
These scripts do **not** measure native heap allocation, peak RSS, or native CPU
profiles. Benchee's BEAM-process memory/reductions would not measure those either.
Use native allocation/CPU profiling before making memory or CPU attribution
claims; `perf`, `heaptrack`, and `valgrind` were unavailable in this environment.

The draw probe uses ExRatatui's in-memory ANSI session. It covers decoding,
Ratatui paint/diff and ANSI generation/draining, but not tty writes, compositor,
or terminal-emulator rendering. It separately checks unchanged draws and draws
with changing selection backgrounds; the latter must actually emit output.
Stage medians are not additive estimates of an end-to-end frame.

## Local observations

Elixir 1.20.4 / OTP 29, existing installed NIFs, before production changes.
Rounded p50 values from one diagnostic run (repeat before treating as a baseline):

| Operation | Wall time |
| --- | ---: |
| Cached turn refresh: open Elixir fence | 83 ms |
| Cached turn refresh: closed fence + changing prose | 1.6 ms |
| Cached turn refresh: many short prose paragraphs | 6.4 ms |
| Open-fence split | 3.1 ms |
| Code: native highlighting + return terms | 59.7 ms |
| Code: returned terms → Elixir Line structs | 3.1 ms |
| Code: Line structs → Tackle wire rows | 2.8 ms |
| Code: native cell layout (including wire decode) | 11.4 ms |
| Prose: native parse + measurement | 2.6–2.7 ms |
| Short paragraphs: native viewport paint + return rows | 0.045–0.046 ms |
| Single long paragraph: native viewport paint + return rows | 1.74–1.77 ms |
| Code viewport: native paint + return rows | 0.20 ms |
| Code viewport: Surface.place / ExRatatui encoding | 0.013 / 0.030 ms |
| Code viewport: pre-encoded native unchanged draw + ANSI drain | 0.35 ms |
| Code viewport: bridge + selection-changing draw + ANSI drain | 0.56 ms |

The existing benchmark's paint stops at `Widgets.Conversation.render/2`, before
ExRatatui encoding/drawing. Its prose fixture has short paragraphs, which masks
the long-logical-line paint cost. The new probe covers both gaps.

## Ranked candidates (not implemented)

1. **Incremental code highlighting.** `Widgets.Conversation.assistant_cell/5`
   highlights the entire changed fence through `ExRatatui.CodeBlock.highlight/3`.
   ExRatatui's `widgets/highlighter.rs::lines_for` creates a fresh `HighlightLines`
   and traverses all source lines. Completed segment reuse from `d274690` works,
   but the live fence still pays this on every source change. An upstream
   stateful highlighter could retain parser/highlight state at complete-line
   checkpoints and restart at the changed line, preserving multiline syntax
   context. This requires an explicit dependency API change, not editing `deps/`
   or independently highlighting arbitrary lines. It is the largest measured
   stage and exceeds the CLI's 32 ms stream-frame interval for this fixture.
2. **Reduce code/plain layout allocation churn.** Tackle's
   `widgets/conversation.rs::grapheme_wrap` allocates an owned span per grapheme;
   `HistoryCell::new` then sanitizes/reallocates those spans, and paint clones
   lines again. Coalescing adjacent same-style graphemes during layout is a
   focused candidate. Validate Unicode width, combining characters, indentation,
   style boundaries, and clipping. The 11.4 ms is the whole NIF stage, not a
   measurement of allocation time specifically.
3. **Cache actual wrapped prose rows, not only heights.** `HistoryCell::new`
   measures with `Paragraph::line_count`, but `HistoryCell::render` clones each
   visible logical line and runs a wrapping `Paragraph` again. The section/line
   indexes avoid offscreen cells, not the rest of one huge logical paragraph.
   Cache compact styled wrapped rows or row boundaries using identical Ratatui
   wrapping semantics. Avoid retaining a full transcript-sized screen buffer;
   measure native retained memory as well as paint time. Parsing must still
   include the complete changed Markdown segment (later reference definitions
   can affect earlier content).
4. **Only then optimize the final bridge/draw.** There are real owned-data
   conversions and a second paint through ExRatatui, but the measured viewport
   costs are sub-millisecond here. Do not introduce cross-NIF pointers/resources
   or a new rendering architecture to solve a much smaller measured stage.

No production rendering behavior was changed by this investigation.
