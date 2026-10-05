defmodule Tackle.SDK do
  @moduledoc """
  JSON-RPC over stdio SDK server for Tackle.

  `Tackle.SDK` lets non-BEAM clients drive a Tackle agent: the host embeds
  the server (configured with its LLM adapters and tool registry), clients
  spawn the host binary and speak newline-delimited JSON-RPC 2.0 over
  stdin/stdout. The wire contract is specified in `PROTOCOL.md`.

  This package is a thin server above [`Tackle.Lib`](../tackle_lib/README.md);
  it adds no agent behaviour of its own. Tools are server-side only in this
  version: clients select from the host's registry per session.

  ## Quick start

      Tackle.SDK.Server.run(
        adapters: [MyApp.CodexAdapter],
        tools: [MyApp.Tools.Search, MyApp.Tools.Fetch]
      )

  A minimal client session (any language):

      {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
      {"jsonrpc":"2.0","id":2,"method":"session/new","params":{"model":"my-adapter/my-model"}}
      {"jsonrpc":"2.0","id":3,"method":"turn/start","params":{"sessionId":"...","input":"hello"}}
      # ... "event" notifications stream back, then:
      {"jsonrpc":"2.0","method":"turn/end","params":{"turnId":"...","result":"ok"}}
  """

  alias Tackle.SDK.Protocol
  alias Tackle.SDK.Server

  @doc "Protocol version implemented by this server (see `PROTOCOL.md`)."
  @spec protocol_version() :: pos_integer()
  defdelegate protocol_version, to: Protocol

  @doc """
  Starts the SDK server and blocks until input ends and turns settle.

  See `Tackle.SDK.Server.run/1` for options.
  """
  @spec run(keyword()) :: :ok | {:error, term()}
  defdelegate run(opts \\ []), to: Server
end
