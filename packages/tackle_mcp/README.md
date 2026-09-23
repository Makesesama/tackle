# Tackle MCP

`Tackle.Plugins.MCP` connects Tackle to external Model Context Protocol servers
and exposes their tools as ordinary `Tackle.Lib.Tool` modules. It uses
[Anubis MCP](https://hex.pm/packages/anubis_mcp) 2.x as the MCP client and keeps
MCP dependencies out of `tackle_lib` and the root harness.

This package is the client-side counterpart to `packages/tackle_anubis`, which
exposes local Tackle tools through an MCP server.

## Scope

The initial plugin supports:

- MCP tools (`tools/list` and `tools/call`)
- STDIO and Streamable HTTP transports
- paginated tool discovery
- stable server-qualified names such as `mcp__github__create_issue`
- text, image, resource-link, and structured tool results

Resources, prompts, live `tools/list_changed` synchronization, and automatic
Streamable HTTP session recovery are deferred. Anubis supervises STDIO client
and transport processes with `:one_for_all`, so a crashed STDIO server is
restarted and initialized again; the tool definitions returned by `connect/1`
remain the startup snapshot.

## Installation

This is currently an in-repo path plugin:

```elixir
defp deps do
  [
    {:tackle_mcp, path: "packages/tackle_mcp"}
  ]
end
```

The plugin requires Elixir `~> 1.18`, `:tackle_lib`, and `:anubis_mcp ~> 2.0`.
Anubis is LGPL-3.0 licensed; account for that when distributing a bundled
release.

## STDIO usage

Connection definitions are trusted host code. Start connections before creating
a Tackle session, then add the discovered modules to that session's tool list:

```elixir
{:ok, mcp} =
  Tackle.Plugins.MCP.connect(
    server_name: "filesystem",
    transport:
      {:stdio,
       command: "npx",
       args: ["-y", "@modelcontextprotocol/server-filesystem", File.cwd!()]}
  )

tools = Tackle.Tools.default() ++ Tackle.Plugins.MCP.tools(mcp)

{:ok, config} =
  Tackle.Config.new(
    adapters: [MyAdapter],
    model: "my-adapter/my-model",
    tools: tools
  )

# Start a scope with the config, then stop the MCP connection during shutdown.
:ok = Tackle.Plugins.MCP.disconnect(mcp)
```

`server_name` must match `[A-Za-z0-9_-]{1,32}` and is the stable local identity
used to namespace tools. The plugin never trusts the remote server's announced
name for model-facing identities. Invalid or long remote names are normalized to
the provider-compatible 64-character alphabet and receive a deterministic hash.
The original MCP name is always used on the wire.

STDIO `:env` is passed to Anubis. Avoid inheriting or forwarding unrelated
secrets; explicitly provide only credentials needed by the server.

## Streamable HTTP usage

Anubis 2.x requires the host to supervise a Finch pool. Pass its name explicitly:

```elixir
children = [
  {Finch, name: MyApp.MCPFinch}
]

{:ok, mcp} =
  Tackle.Plugins.MCP.connect(
    server_name: "search",
    transport:
      {:streamable_http,
       base_url: "https://mcp.example.com",
       mcp_path: "/mcp",
       headers: %{"authorization" => "Bearer ..."},
       finch_name: MyApp.MCPFinch,
       enable_sse: true}
  )
```

Use the credential mechanism owned by your host rather than placing bearer
values in general Tackle session configuration.

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `:server_name` | required | Stable local namespace for one server |
| `:transport` | required | `{:stdio, opts}` or `{:streamable_http, opts}` |
| `:connect_timeout` | `30_000` | Initialization wait in milliseconds |
| `:discovery_timeout` | `30_000` | Timeout for each `tools/list` page |
| `:tool_call_timeout` | `60_000` | Timeout for each `tools/call` |

## Schema behavior

MCP uses JSON Schema while Tackle's current tool contract uses a smaller keyword
schema. The plugin conservatively projects top-level object properties and
preserves primitive/object/array types, required fields, descriptions, defaults,
and enums. Nested object constraints remain server-validated. Unions, references,
missing or unknown property types, and other schemas that cannot be represented
faithfully are rejected during discovery rather than advertised inaccurately.
MCP output schemas are retained as opaque metadata; Anubis validates advertised
structured results after discovery.

Discovered field names and proxy modules are created at trusted startup and
therefore consume VM atoms/modules for the life of the BEAM. Do not repeatedly
connect to untrusted servers with unbounded, changing tool schemas.

## Development

```sh
mix deps.get
mix compile --warnings-as-errors
mix test
mix format --check-formatted 'mix.exs' 'lib/**/*.{ex,exs}' 'test/**/*.{ex,exs}'
```

## OAuth for Streamable HTTP

`Tackle.Plugins.MCP.OAuth` is a functional OAuth helper; the host owns browser
launch, loopback listener, and credential storage. Start a flow, open its URL,
then pass the callback's `state` and `code` to `complete/3`:

```elixir
{:ok, flow} = Tackle.Plugins.MCP.OAuth.begin("https://mcp.example.com/mcp",
  redirect_uri: "http://localhost:49152/callback",
  finch_name: MyApp.MCPFinch,
  client_id: "registered-client", # optional; DCR is used if omitted
  scope: "tools")

# Open flow.authorization_url in a browser and receive callback parameters.
{:ok, credentials} = Tackle.Plugins.MCP.OAuth.complete(flow, callback_state,
  code: authorization_code)
# Persist credentials securely in host-owned storage.
```

The API performs protected-resource metadata discovery (well-known endpoint,
then `WWW-Authenticate` challenge), authorization-server metadata discovery
(with OpenID Connect discovery fallback), optional dynamic client registration,
PKCE S256, resource-indicated authorization/code exchange, and token refresh.
`complete/3` checks state with a constant-time comparison. Credentials are
returned as a map containing `:access_token`, `:refresh_token` (if issued),
`:client_id`, `:client_secret` (if issued), `:token_endpoint`, and `:resource`;
store that map in a secure credential store. `refresh/2` returns an updated map.
For hermetic tests, pass `request: fn method, url, headers, body, opts -> ... end`
instead of `finch_name:`. OAuth operations use Finch when no injected request
function is provided. Network metadata and endpoints require HTTPS; HTTP is
permitted only for loopback URLs.

OAuth credentials are supplied as bearer headers by the CLI. Anubis 2.0's
307 redirect handler currently raises on redirects instead of following them;
configure the final MCP endpoint URL directly. Transport headers are static
by default; the CLI updates the live Anubis HTTP transport on refresh. Other
hosts must manage token rotation themselves. Anubis debug logs include bearer
headers, so the CLI disables those logs. Loopback callback security/lifecycle
and secure persistence are the frontend's responsibility.
