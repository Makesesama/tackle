# Tackle SDK Wire Protocol

Version 1 (experimental). This document is the contract between the Tackle
SDK server (`packages/tackle_sdk`) and client SDKs in other languages. Client
implementations should be written against this document, not the server
source.

## Transport

The client spawns the host binary and communicates over the process's
**stdin/stdout** using **newline-delimited JSON-RPC 2.0** (ndjson): exactly one
JSON-RPC message per line, UTF-8, terminated by `\n`. Blank lines are ignored.
The server never writes partial lines, so clients can read with a plain
line reader. Server-side logs go to stderr and must be ignored by clients.

Frames are standard JSON-RPC 2.0: requests carry `jsonrpc`, `id`, `method`,
and optional `params`; responses carry `id` with either `result` or `error`;
notifications carry `method`/`params` with no `id`.

## Lifecycle

1. The client sends `initialize` and waits for the response. Every other
   request is rejected with code `-32002` until the handshake completes.
2. The client creates one or more sessions (`session/new`) and runs turns on
   them (`turn/start`).
3. The server stops when stdin reaches EOF (or after a `shutdown` request)
   **and** all in-flight turns have settled. Clients that close stdin while a
   turn is running still receive its `event` notifications and final
   `turn/end`.

## Requests

### `initialize`

```jsonc
// request
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
// response
{"jsonrpc":"2.0","id":1,"result":{
  "protocolVersion":1,
  "serverInfo":{"name":"tackle-sdk","version":"0.1.0"},
  "capabilities":{}
}}
```

`protocolVersion` is an integer. A client that does not support the returned
version should exit. New fields inside `result` may be added in later
revisions; clients must ignore unknown fields.

### `tools/list`

Lists the server-side tool registry. Tools execute on the server; clients
only select a subset per session.

```jsonc
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
{"jsonrpc":"2.0","id":2,"result":{"tools":[
  {"name":"echo","description":"Echoes text","parameters":{"type":"object","properties":{...},"required":[...]}}
]}}
```

`parameters` is a JSON Schema object.

### `session/new`

Creates an agent session and returns its id.

```jsonc
{"jsonrpc":"2.0","id":3,"method":"session/new","params":{
  "sessionId":"optional-client-chosen-id",   // default: server-generated UUID
  "model":"adapter_id/model",                // default: first model of the first adapter
  "systemPrompt":"optional system prompt",
  "tools":["echo"],                          // default: all registered tools
  "maxIterations":10                         // optional, default: unlimited
}}
{"jsonrpc":"2.0","id":3,"result":{"sessionId":"..."}}
```

Errors: unknown model ref, unknown tool name, or duplicate `sessionId`
(`-32602`).

### `turn/start`

Starts one agent turn on a session. The server responds **immediately** with
the turn id; the turn's progress and result arrive as notifications. One turn
at a time per session.

```jsonc
{"jsonrpc":"2.0","id":4,"method":"turn/start","params":{
  "sessionId":"...",
  "input":"user message",
  "turnId":"optional-client-chosen-id"       // default: server-generated UUID
}}
{"jsonrpc":"2.0","id":4,"result":{"turnId":"..."}}
```

Errors: unknown `sessionId` (`-32602`), or an active turn already exists on
the session (`-32000`).

### `turn/cancel`

Best-effort cooperative cancellation of a running turn.

```jsonc
{"jsonrpc":"2.0","id":5,"method":"turn/cancel","params":{"turnId":"..."}}
{"jsonrpc":"2.0","id":5,"result":{"turnId":"...","cancelled":true}}
```

The turn settles with a `turn/end` notification whose `result` is
`"cancelled"` at the next cancellation boundary (after the current provider
call or tool execution). Unknown or already-finished turns return `-32602`.

### `shutdown`

```jsonc
{"jsonrpc":"2.0","id":6,"method":"shutdown","params":{}}
{"jsonrpc":"2.0","id":6,"result":{}}
```

The server stops after responding, once in-flight turns settle.

## Server-to-client notifications

### `event`

One notification per `Tackle.Lib` loop event, in order, for the lifetime of
a turn:

```jsonc
{"jsonrpc":"2.0","method":"event","params":{
  "turnId":"...",
  "event":{
    "type":"tool_start",
    "id":"evt_42",
    "parentId":"evt_41",
    "data":{...},
    "timestamp":"2026-02-14T12:00:00Z",
    "metadata":{}
  }
}}
```

`type` is one of the Tackle.Lib event types: `turn_start`, `turn_end`,
`turn_cancelled`, `step_start`, `step_end`, `message_start`,
`message_delta`, `message_end`, `tool_start`, `tool_progress`,
`tool_execution_end`, `tool_end`, `tool_error`, `subagent_started`,
`subagent_progress`, `subagent_finished`, `usage`, `status_change`, `error`,
`provider_event`, `compaction_start`, `compaction_end`, `compaction_retry`,
`retry_scheduled`, `retry_start`, `retry_end`.

The `data` payload is event-type specific. New event types and new `data`
fields may be added in minor revisions; clients must ignore both.

### `turn/end`

Exactly one per started turn, after all of its `event` notifications:

```jsonc
{"jsonrpc":"2.0","method":"turn/end","params":{
  "turnId":"...",
  "result":"ok"          // "ok" | "error" | "cancelled"
  ,"error":"..."        // present only when result is "error"
}}
```

### `server/error`

Emitted when the input stream fails (e.g. the IO device errors). Treat it as
a fatal condition.

## Error codes

| Code | Meaning |
|---|---|
| `-32700` | Parse error (invalid JSON); the response id is `null`. |
| `-32600` | Invalid request (not a JSON-RPC 2.0 frame). |
| `-32601` | Method not found. |
| `-32602` | Invalid params (unknown session/turn/tool/model, duplicate id). |
| `-32603` | Internal error. |
| `-32002` | Server not initialized. |
| `-32000` | Turn conflict: the session already has an active turn. |

## Reserved for future revisions

These method names are reserved and must be treated as unknown (they will
return `-32601` until implemented):

* `tool/execute` — server-to-client request letting clients supply tools.
* `interaction/confirm`, `interaction/prompt` — server-to-client approval
  and input requests.
* `session/history` — conversation transcript retrieval.
* `turn/retry` — re-run an errored turn without a new user message.

## Versioning

`protocolVersion` starts at `1`. Additive changes (new methods, new event
types, new fields) bump the minor revision without changing the integer;
breaking changes bump the integer. Until this protocol leaves experimental
status, pin clients and the server to the same repository revision.
