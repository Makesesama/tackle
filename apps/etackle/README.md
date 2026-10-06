# etackle

An Emacs client for the Tackle SDK: the first non-BEAM client speaking
the [SDK wire protocol](../../packages/tackle_sdk/PROTOCOL.md). It
spawns `tackle sdk`, drives agent sessions over newline-delimited
JSON-RPC 2.0 on stdio, and renders the streamed turn events as a
conversation.

This is a deliberately **basic** first client: one session per
directory, one turn at a time, streamed assistant text, one-line tool
summaries, and a client-side queue for prompts typed while a turn is
running.

## Requirements

- Emacs 28.1 or later
- The `tackle` CLI (built from `apps/tackle_cli`), which serves the
  SDK protocol via `tackle sdk`

## Usage

Add this directory to `load-path` and load the package:

```elisp
(add-to-list 'load-path "/path/to/tackle/apps/etackle")
(require 'etackle)
```

Then:

- `M-x etackle` — start or switch to a session for
  `default-directory`. The conversation renders in a read-only chat
  buffer on top; prompts are composed in an ordinary editable buffer
  below it.
- `C-c C-c` (input buffer) — send the prompt. If a turn is running,
  the prompt is queued and sent when the turn ends.
- `C-c C-k` (chat buffer) — request cancellation of the running turn.
- `Q` (chat buffer) — kill the session (server process and both
  buffers). `q` merely buries the buffer; the session keeps running.

The chat buffer's mode line shows the session status (`starting`,
`ready`, `running (thinking)`/`running (acting)`, `dead`) and the
token usage of the latest `usage` event.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `etackle-program` | `"tackle"` | CLI binary serving the SDK |
| `etackle-sdk-args` | `'("sdk")` | Arguments for the binary |
| `etackle-model` | `"openai-codex/gpt-6.1-sol"` | Model ref for new sessions |
| `etackle-system-prompt` | `nil` | Optional system prompt |
| `etackle-delta-flush-interval` | `0.05` | Seconds to batch streamed text |

The model is **pinned** because SDK protocol version 1 has no model
discovery: `session/new` takes an `"adapter/model"` ref, but there is
no way to list adapters or models over the wire. `etackle-model` is
set to `openai-codex/gpt-6.1-sol` for testing with the bundled Codex
adapter.

## Design

Two files, roughly 1,000 lines total:

- `etackle-rpc.el` — transport: spawn the process, ndjson framing,
  request-id correlation, notification dispatch. Knows frames, not
  agent semantics. Non-JSON stdout lines (the Burrito wrapper of the
  `tackle` binary prints boot messages to stdout) and server stderr
  are logged to `*etackle-server-log*` instead of aborting the stream.
- `etackle.el` — session state machine, chat/input buffers, event
  rendering, prompt queue.

Borrowed patterns, with the architecture notes in mind:

- From **pilish**: per-process request correlation, chunked line
  accumulation, a 50 ms delta-coalescing timer (per-delta insertion
  makes display quadratic in long replies), failing pending requests
  with a synthesized error when the process dies, and buffer-local
  session state.
- From **agent-shell**: rendering above a persistent composition
  buffer, and tolerating incomplete markdown while streaming (the chat
  buffer shows raw markdown text; no rewriter yet).

The protocol's shape keeps the client simple: `turn/start` responds
immediately with the turn id, every turn settles with exactly one
`turn/end` notification, and tools are server-side only, so there is
no approval UI. Unknown event types and data fields are ignored, as
`PROTOCOL.md` requires.

## Known limitations

- Sessions live and die with the server process. The protocol has no
  `session/history` yet, so a crashed or quit session cannot be
  resumed; start a new one with `M-x etackle`.
- Tool results are summarized to one line; there is no expandable
  tool-call display yet.
- No markdown rendering: assistant text streams as plain text.

## Testing

```sh
(cd apps/etackle && emacs -Q --batch -L . -l test/etackle-test.el \
    -f ert-run-tests-batch-and-exit)
```

The tests cover the RPC layer only (framing, correlation, error and
exit paths) and use a pipe process instead of the real server, so they
need no `tackle` binary or provider credentials.
