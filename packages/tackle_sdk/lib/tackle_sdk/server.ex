defmodule Tackle.SDK.Server do
  @moduledoc """
  Stdio JSON-RPC server exposing the `Tackle.Lib` agent loop to non-BEAM clients.

  A client spawns the host binary, speaks newline-delimited JSON-RPC 2.0 on
  stdin/stdout (see `PROTOCOL.md`), and drives agent sessions: `initialize`,
  `session/new`, `turn/start`, `turn/cancel`. Turn events stream back as
  `event` notifications and finish with a `turn/end` notification.

  Tools are **server-side only** in this version: the host configures a tool
  registry, and clients select a subset of it per session. Client-supplied
  tools (`tool/execute` server-to-client requests) are reserved for a later
  protocol revision.

  ## Options

    * `:adapters` — list of `Tackle.Lib.LLM` adapter modules the client can
      select models from (required for `session/new`).
    * `:tools` — list of `Tackle.Lib.Tool` modules forming the server-side
      registry (default: `[]`).
    * `:input` — `:stdio` (default), an IO device, or a list of pre-fed lines
      (used by tests).
    * `:output` — `:stdio` (default), an IO device, or a one-argument fun
      receiving each encoded line (used by tests).
    * `:context` — map merged into the tool execution context of every
      session (default: `%{}`). Hosts use it for facts tools need, such as
      `cwd` or user identity.
    * `:owner` — process notified with `{:sdk_done, :ok}` just before a clean
      stop; set automatically by `run/1`.

  ## Example

      Tackle.SDK.Server.run(
        adapters: [MyApp.CodexAdapter],
        tools: [MyApp.Tools.Search]
      )
  """

  use GenServer

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.LLM
  alias Tackle.Lib.Loop
  alias Tackle.Lib.State
  alias Tackle.Lib.Tool.Schema.JsonSchema
  alias Tackle.SDK.Protocol

  @default_max_iterations :infinity

  # Client API

  @doc """
  Starts the server and blocks until it stops.

  The server stops when its input reaches EOF (or a `shutdown` request
  completes) and no turns are still running. Returns `:ok` on a clean stop,
  `{:error, reason}` if the server crashed.
  """
  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts \\ []) do
    {:ok, pid} = start_link(Keyword.put(opts, :owner, self()))
    ref = Process.monitor(pid)

    receive do
      {:sdk_done, :ok} ->
        :ok

      {:DOWN, ^ref, :process, ^pid, reason} when reason in [:normal, :shutdown] ->
        :ok

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, reason}
    end
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    {:ok, task_sup} = Task.Supervisor.start_link()

    state = %{
      adapters: Keyword.get(opts, :adapters, []),
      tools: Keyword.get(opts, :tools, []),
      input: Keyword.get(opts, :input, :stdio),
      output: Keyword.get(opts, :output, :stdio),
      context: Keyword.get(opts, :context, %{}),
      task_sup: task_sup,
      owner: Keyword.get(opts, :owner),
      initialized?: false,
      sessions: %{},
      turns: %{},
      pending_stop?: false
    }

    start_reader(state)
    {:ok, state}
  end

  # Reader

  defp start_reader(state) do
    server = self()

    spawn_link(fn ->
      read_input(state.input, server)
    end)
  end

  defp read_input(:stdio, server), do: read_device(:stdio, server)

  defp read_input(lines, server) when is_list(lines) do
    Enum.each(lines, &send(server, {:line, &1}))
    send(server, :eof)
  end

  defp read_input(device, server), do: read_device(device, server)

  defp read_device(device, server) do
    case IO.read(device, :line) do
      :eof ->
        send(server, :eof)

      {:error, reason} ->
        send(server, {:input_error, reason})

      data ->
        send(server, {:line, IO.chardata_to_string(data)})
        read_device(device, server)
    end
  end

  # Incoming frames

  @impl true
  def handle_info({:line, line}, state) do
    case Protocol.decode(line) do
      :ignore ->
        {:noreply, state}

      {:error, code, message} ->
        write(state, Protocol.error_response(nil, code, message))
        {:noreply, state}

      {:ok, request} ->
        state = dispatch(request, state)
        maybe_stop(state)
    end
  end

  def handle_info(:eof, state) do
    state = %{state | pending_stop?: true}
    maybe_stop(state)
  end

  def handle_info({:input_error, reason}, state) do
    # Input is gone; surface the failure and stop once turns settle.
    write(
      state,
      Protocol.notification("server/error", %{"message" => "input failed: #{inspect(reason)}"})
    )

    maybe_stop(%{state | pending_stop?: true})
  end

  # Turn lifecycle

  def handle_info({:sdk_event, turn_id, %Tackle.Lib.Event{} = event}, state) do
    write(
      state,
      Protocol.notification("event", %{
        "turnId" => turn_id,
        "event" => Protocol.serialize_event(event)
      })
    )

    {:noreply, state}
  end

  def handle_info({:turn_done, turn_id, status, %State{} = new_state}, state) do
    case Map.pop(state.turns, turn_id) do
      {nil, _turns} ->
        {:noreply, state}

      {turn, turns} ->
        Process.demonitor(turn.monitor_ref, [:flush])

        sessions =
          Map.update!(state.sessions, turn.session_id, fn _old ->
            new_state
          end)

        params = %{"turnId" => turn_id, "result" => status}

        params =
          if status == :error,
            do: Map.put(params, "error", Protocol.json_safe(new_state.error)),
            else: params

        write(state, Protocol.notification("turn/end", params))
        maybe_stop(%{state | sessions: sessions, turns: turns})
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case find_turn_by_monitor(state.turns, ref) do
      nil ->
        {:noreply, state}

      {turn_id, _turn} ->
        turns = Map.delete(state.turns, turn_id)

        write(
          state,
          Protocol.notification("turn/end", %{
            "turnId" => turn_id,
            "result" => "error",
            "error" => "turn task exited: #{inspect(reason)}"
          })
        )

        maybe_stop(%{state | turns: turns})
    end
  end

  # Dispatch

  defp dispatch(%{method: "initialize"} = request, state) do
    respond(state, request, %{
      "protocolVersion" => Protocol.protocol_version(),
      "serverInfo" => %{"name" => "tackle-sdk", "version" => server_version()},
      "capabilities" => %{}
    })

    %{state | initialized?: true}
  end

  defp dispatch(%{method: method} = request, state) when method != "initialize" do
    if state.initialized? do
      dispatch_initialized(request, state)
    else
      respond_error(
        state,
        request,
        Protocol.not_initialized_code(),
        "server not initialized: send initialize first"
      )

      state
    end
  end

  defp dispatch_initialized(%{method: "tools/list"} = request, state) do
    tools =
      Enum.map(state.tools, fn tool ->
        %{
          "name" => tool.name(),
          "description" => tool.description(),
          "parameters" => JsonSchema.to_json_schema(tool.parameters_schema())
        }
      end)

    respond(state, request, %{"tools" => tools})
    state
  end

  defp dispatch_initialized(%{method: "session/new"} = request, state) do
    params = request.params

    with {:ok, session_id} <- unique_session_id(params, state),
         {:ok, tools} <- select_tools(params, state),
         {:ok, selection} <- select_model(params, state) do
      session =
        State.new(
          session_id: session_id,
          llm: selection,
          tools: tools,
          system_prompt: params["systemPrompt"],
          context: state.context,
          max_iterations: max_iterations(params)
        )

      respond(state, request, %{"sessionId" => session.session_id})
      %{state | sessions: Map.put(state.sessions, session.session_id, session)}
    else
      {:error, message} ->
        respond_error(state, request, Protocol.invalid_params_code(), message)
        state
    end
  end

  defp dispatch_initialized(%{method: "turn/start"} = request, state) do
    params = request.params
    session_id = params["sessionId"]

    cond do
      not is_binary(session_id) or not Map.has_key?(state.sessions, session_id) ->
        respond_error(state, request, Protocol.invalid_params_code(), "unknown sessionId")
        state

      session_has_active_turn?(state, session_id) ->
        respond_error(
          state,
          request,
          Protocol.turn_conflict_code(),
          "session already has an active turn"
        )

        state

      true ->
        session = Map.fetch!(state.sessions, session_id)
        turn_id = turn_id(params, session)
        signal = Cancellation.new_signal()
        server = self()

        {:ok, task_pid} =
          Task.Supervisor.start_child(state.task_sup, fn ->
            result =
              Loop.run(session, params["input"] || "",
                turn_id: turn_id,
                cancellation_signal: signal,
                event_callback: fn event -> send(server, {:sdk_event, turn_id, event}) end
              )

            {status, final_state} = result
            send(server, {:turn_done, turn_id, status, final_state})
          end)

        monitor_ref = Process.monitor(task_pid)

        turns =
          Map.put(state.turns, turn_id, %{
            session_id: session_id,
            monitor_ref: monitor_ref,
            signal: signal
          })

        respond(state, request, %{"turnId" => turn_id})
        %{state | turns: turns}
    end
  end

  defp dispatch_initialized(%{method: "turn/cancel"} = request, state) do
    turn_id = request.params["turnId"]

    case Map.fetch(state.turns, turn_id) do
      {:ok, turn} ->
        Cancellation.cancel(turn.signal)
        respond(state, request, %{"turnId" => turn_id, "cancelled" => true})
        state

      :error ->
        respond_error(
          state,
          request,
          Protocol.invalid_params_code(),
          "unknown or finished turnId"
        )

        state
    end
  end

  defp dispatch_initialized(%{method: "shutdown"} = request, state) do
    respond(state, request, %{})
    %{state | pending_stop?: true}
  end

  defp dispatch_initialized(%{id: nil}, state) do
    # Client notifications expect no response; nothing to do yet.
    state
  end

  defp dispatch_initialized(%{method: method} = request, state) do
    respond_error(state, request, Protocol.method_not_found_code(), "unknown method: #{method}")
    state
  end

  # Helpers

  defp maybe_stop(state) do
    if state.pending_stop? and map_size(state.turns) == 0 do
      if state.owner, do: send(state.owner, {:sdk_done, :ok})
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  defp respond(_state, %{id: nil}, _result), do: :ok

  defp respond(state, request, %{} = result) do
    write(state, Protocol.response(request.id, result))
  end

  defp respond_error(_state, %{id: nil}, _code, _message), do: :ok

  defp respond_error(state, request, code, message) do
    message = if is_binary(message), do: message, else: inspect(message)
    write(state, Protocol.error_response(request.id, code, message))
  end

  defp write(state, frame) do
    line = Protocol.encode_line(frame)

    case state.output do
      output when is_function(output, 1) -> output.(line)
      device -> IO.write(device, line)
    end
  end

  defp unique_session_id(params, state) do
    case params["sessionId"] do
      nil ->
        {:ok, nil}

      session_id when is_binary(session_id) and session_id != "" ->
        if Map.has_key?(state.sessions, session_id) do
          {:error, "session already exists: #{session_id}"}
        else
          {:ok, session_id}
        end

      _ ->
        {:error, "sessionId must be a non-empty string when given"}
    end
  end

  defp select_tools(params, state) do
    case params["tools"] do
      nil ->
        {:ok, state.tools}

      names when is_list(names) ->
        by_name = Map.new(state.tools, fn tool -> {tool.name(), tool} end)

        Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
          case Map.fetch(by_name, name) do
            {:ok, tool} -> {:cont, {:ok, [tool | acc]}}
            :error -> {:halt, {:error, "unknown tool: #{inspect(name)}"}}
          end
        end)
        |> case do
          {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
          error -> error
        end

      _ ->
        {:error, "tools must be a list of tool names"}
    end
  end

  defp select_model(params, state) do
    case params["model"] do
      nil ->
        default_model(state)

      model when is_binary(model) ->
        LLM.select(state.adapters, model)

      _ ->
        {:error, "model must be a string of the form adapter_id/model"}
    end
  end

  defp default_model(%{adapters: []}), do: {:error, "no LLM adapters configured on the server"}

  defp default_model(%{adapters: [adapter | _]}) do
    model = adapter.models() |> List.first()

    if model do
      LLM.select([adapter], "#{adapter.adapter_id()}/#{model}")
    else
      {:error, "adapter #{adapter.adapter_id()} advertises no models"}
    end
  end

  defp max_iterations(params) do
    case params["maxIterations"] do
      nil -> @default_max_iterations
      integer when is_integer(integer) and integer > 0 -> integer
      _ -> @default_max_iterations
    end
  end

  defp session_has_active_turn?(state, session_id) do
    Enum.any?(state.turns, fn {_turn_id, turn} -> turn.session_id == session_id end)
  end

  defp turn_id(params, session) do
    case params["turnId"] do
      id when is_binary(id) and id != "" -> id
      _ -> session.id_generator.()
    end
  end

  defp find_turn_by_monitor(turns, ref) do
    Enum.find(turns, fn {_turn_id, turn} -> turn.monitor_ref == ref end)
  end

  defp server_version do
    case :application.get_key(:tackle_sdk, :vsn) do
      {:ok, version} -> to_string(version)
      :undefined -> "0.0.0"
    end
  end
end
