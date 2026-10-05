# Tackle.SDK

`Tackle.SDK` exposes the [`Tackle.Lib`](../tackle_lib/README.md) agent loop to
clients in any language over **newline-delimited JSON-RPC 2.0 on stdio**. A
client spawns the host binary, drives agent sessions (`initialize`,
`session/new`, `turn/start`, `turn/cancel`), and consumes streamed turn events
until a final `turn/end` notification.

The wire contract is specified in [PROTOCOL.md](PROTOCOL.md) — client SDKs
are written against that document, not against this server's source.

## Status

Experimental. Protocol version 1; the surface may change. Tools are
**server-side only**: the host configures a tool registry and clients select a
subset of it per session. Client-supplied tools (`tool/execute`) and
interactive approval (`interaction/*`) are reserved for later revisions.

## Installation

In-repo path package, not a Hex package. Add alongside `tackle_lib`:

```elixir
defp deps do
  [
    {:tackle_lib, path: "packages/tackle_lib"},
    {:tackle_sdk, path: "packages/tackle_sdk"}
  ]
end
```

`Tackle.SDK` requires Elixir `~> 1.18` and depends only on `:tackle_lib`.

## Usage

The host embeds the server with its LLM adapters and tool registry:

```elixir
Tackle.SDK.run(
  adapters: [MyApp.CodexAdapter],
  tools: [MyApp.Tools.Search, MyApp.Tools.Fetch]
)
```

`run/1` blocks until stdin reaches EOF and all in-flight turns settle, so it
is suitable as the main entrypoint of a `--sdk` mode in a host binary.

A minimal client conversation (any language, one JSON-RPC frame per line on
stdin):

```jsonc
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"model":"my-adapter/my-model"}}
{"jsonrpc":"2.0","id":3,"method":"turn/start","params":{"sessionId":"<from response 2>","input":"hello"}}
```

and reads stdout:

```jsonc
{"jsonrpc":"2.0","method":"event","params":{"turnId":"...","event":{"type":"turn_start",...}}}
{"jsonrpc":"2.0","method":"event","params":{"turnId":"...","event":{"type":"tool_start",...}}}
{"jsonrpc":"2.0","method":"turn/end","params":{"turnId":"...","result":"ok"}}
```

## Design

* `Tackle.SDK.Protocol` — pure JSON-RPC codec and event serialization; no
  processes, fully unit-tested.
* `Tackle.SDK.Server` — a GenServer that owns sessions and turns. Turns run
  under a `Task.Supervisor` so a crashing adapter or tool cannot take down the
  server; the loop's cancellation signal backs `turn/cancel`.
* The server adds no agent behaviour of its own — every event, message, and
  tool contract comes from `Tackle.Lib`.

## Testing

```sh
(cd packages/tackle_sdk && mix deps.get)
(cd packages/tackle_sdk && mix compile --warnings-as-errors && mix test)
(cd packages/tackle_sdk && mix format --check-formatted 'mix.exs' 'lib/**/*.{ex,exs}' 'test/**/*.{ex,exs}')
```

Tests use deterministic fake LLM adapters and tools; no provider credentials
or network access are needed.
