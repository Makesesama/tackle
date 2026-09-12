# Tackle.Anubis

`Tackle.Anubis` exposes [`Tackle.Lib`](../tackle_lib/README.md) tool modules
through an [Anubis](https://hex.pm/packages/anubis_mcp) MCP server. It is a small
bridge, not an agent: the host still owns server startup, transport, OAuth,
scopes, tenant resolution, and the list of tools published on that surface.

## Installation

This package is currently an in-repo path package, not a Hex package. Copy or
extract both sibling packages while preserving this layout:

```text
packages/
  tackle_lib/
  tackle_anubis/
```

Then add:

```elixir
# mix.exs
defp deps do
  [
    {:tackle_lib, path: "packages/tackle_lib"},
    {:tackle_anubis, path: "packages/tackle_anubis"}
  ]
end
```

`Tackle.Anubis` requires Elixir `~> 1.18` and `:anubis_mcp ~> 2.0`.

## Usage

```elixir
defmodule MyApp.MCP.Server do
  use Anubis.Server, capabilities: [:tools]

  @tools [MyApp.Tools.Search, MyApp.Tools.Fetch]

  @impl true
  def init(_client_info, frame) do
    {:ok, Tackle.Anubis.register_all(frame, @tools)}
  end

  @impl true
  def handle_tool_call(name, params, frame) do
    Tackle.Anubis.dispatch(name, params, frame,
      tools: @tools,
      context: &MyApp.MCP.Context.from_frame/1
    )
  end
end
```

`register_all/3` projects each tool's `Tackle.Lib.Tool` schema into the Peri
schema Anubis expects, and `dispatch/4` runs the tool through
`Tackle.Lib.Tool.settle/3`. Validation, output projection, and error mapping are
therefore identical to a tool call made by the agent loop.

### Options

Both functions take options as their last argument:

| Option | Applies to | Meaning |
|---|---|---|
| `:tools` | `dispatch/4` (required) | Tool modules or a `Tackle.Lib.Integrations.Registry` |
| `:context` | `dispatch/4` | Context map, or a 1-arity function of the frame |
| `:call_id` | `dispatch/4` | Explicit tool-call id; defaults to a generated UUID |
| `:description_renderer` | `register_all/3` | Renderer module for host-defined `description_metadata/0` |
| `:annotations` | `register_all/3` | MCP annotations forwarded to `Anubis.Server.Frame.register_tool/3` |
| `:title`, `:task_support`, `:scopes` | `register_all/3` | Registration metadata forwarded to Anubis |

`dispatch/4` returns `{:reply, response, frame}` for known tools and
`{:error, :unknown_tool}` otherwise, leaving protocol error mapping to the host
server.

## Responsibility split

| Concern | Owner |
|---|---|
| Agent loop, tools, schemas, tool settlement | `Tackle.Lib` |
| Peri schema projection and tool dispatch | `Tackle.Anubis` |
| MCP server, transport, sessions | host Anubis server |
| Auth, scopes, tenant/context enrichment | host Anubis server |

## Source layout

- `lib/tackle_anubis.ex` — `Tackle.Anubis`, `register_all/3` and `dispatch/4`
- `lib/tackle_anubis/schema.ex` — `Tackle.Anubis.Schema`, keyword schema to Peri
