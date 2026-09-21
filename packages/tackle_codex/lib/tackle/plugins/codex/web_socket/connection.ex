defmodule Tackle.Plugins.Codex.WebSocket.Connection do
  @moduledoc false

  use GenServer, restart: :temporary

  alias Tackle.Plugins.Codex.WebSocket

  @registry Tackle.Plugins.Codex.WebSocket.Registry
  @receive_poll_timeout 100
  @previous_response_not_found "previous_response_not_found"

  defstruct [
    :key,
    :lease,
    :url,
    :headers,
    :connect_timeout,
    :receive_timeout,
    :idle_timeout,
    :idle_timer,
    :connection,
    :websocket,
    :request_ref,
    :response_id,
    :continuation
  ]

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :key)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts) do
    key = Keyword.fetch!(opts, :key)
    lease = Keyword.fetch!(opts, :lease)
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {@registry, key, lease}})
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      key: Keyword.fetch!(opts, :key),
      lease: Keyword.fetch!(opts, :lease),
      url: Keyword.fetch!(opts, :url),
      headers: Keyword.fetch!(opts, :headers),
      connect_timeout: Keyword.fetch!(opts, :connect_timeout),
      receive_timeout: Keyword.fetch!(opts, :receive_timeout),
      idle_timeout: Keyword.fetch!(opts, :idle_timeout)
    }

    {:ok, schedule_idle(state)}
  end

  @impl true
  def handle_info({:request, caller, request_id, body, use_continuation?}, state) do
    state = cancel_idle(state)
    monitor = Process.monitor(caller)

    {result, state} =
      run_request(state, caller, request_id, body, use_continuation?, monitor, false)

    Process.demonitor(monitor, [:flush])

    case result do
      :ok ->
        send(caller, {:websocket_done, request_id})
        :atomics.put(state.lease, 1, 0)
        {:noreply, schedule_idle(state)}

      {:error, phase, reason} ->
        send(caller, {:websocket_error, request_id, phase, reason})
        {:stop, :normal, state}
    end
  end

  def handle_info({:idle_timeout, token}, %{idle_timer: {_timer, token}} = state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close_connection(state)
    :ok
  end

  defp run_request(state, caller, request_id, full_body, use_continuation?, monitor, retried?) do
    with :ok <- request_open(state, caller, request_id, monitor),
         {:ok, state} <- ensure_connected(state),
         :ok <- request_open(state, caller, request_id, monitor),
         state <- %{state | response_id: nil},
         {request_body, _request_kind} <-
           continuation_body(state, full_body, use_continuation?),
         {:ok, state} <- send_request(state, request_body),
         {:ok, terminal_event, state} <-
           receive_response(
             state,
             caller,
             request_id,
             monitor,
             false,
             deadline(state.receive_timeout)
           ) do
      state = update_continuation(state, full_body, terminal_event, use_continuation?)
      {:ok, state}
    else
      {:error, :previous_response_not_found, state}
      when use_continuation? and not retried? ->
        state = state |> close_connection() |> Map.put(:continuation, nil)
        run_request(state, caller, request_id, full_body, use_continuation?, monitor, true)

      {:error, phase, reason, state} ->
        {{:error, phase, reason}, state |> close_connection() |> Map.put(:continuation, nil)}

      {:error, reason} ->
        {{:error, :before_stream, reason},
         state |> close_connection() |> Map.put(:continuation, nil)}
    end
  end

  defp request_open(state, caller, request_id, monitor) do
    receive do
      {:cancel, ^caller, ^request_id} ->
        {:error, :before_stream, :cancelled, state}

      {:DOWN, ^monitor, :process, ^caller, reason} ->
        {:error, :before_stream, {:caller_stopped, reason}, state}
    after
      0 -> :ok
    end
  end

  defp continuation_body(state, body, true) do
    WebSocket.continuation_request(body, state.continuation)
  end

  defp continuation_body(_state, body, false), do: {body, :full}

  defp ensure_connected(%__MODULE__{connection: nil} = state), do: connect(state)
  defp ensure_connected(state), do: {:ok, state}

  defp connect(state) do
    uri = URI.parse(state.url)
    http_scheme = if uri.scheme == "wss", do: :https, else: :http
    websocket_scheme = if uri.scheme == "wss", do: :wss, else: :ws
    port = uri.port || if(http_scheme == :https, do: 443, else: 80)

    transport_opts =
      [timeout: state.connect_timeout]
      |> maybe_put_cacerts(http_scheme)

    connect_opts = [
      mode: :passive,
      protocols: [:http1],
      transport_opts: transport_opts
    ]

    with {:ok, connection} <- Mint.HTTP.connect(http_scheme, uri.host, port, connect_opts),
         {:ok, connection, request_ref} <-
           Mint.WebSocket.upgrade(
             websocket_scheme,
             connection,
             request_path(uri),
             state.headers
           ),
         {:ok, connection, status, response_headers} <-
           await_upgrade(connection, request_ref, nil, [], deadline(state.connect_timeout)),
         {:ok, connection, websocket} <-
           Mint.WebSocket.new(connection, request_ref, status, response_headers, mode: :passive) do
      {:ok,
       %{
         state
         | connection: connection,
           websocket: websocket,
           request_ref: request_ref
       }}
    else
      {:error, connection, %Mint.WebSocket.UpgradeFailureError{status_code: status} = error} ->
        Mint.HTTP.close(connection)
        {:error, {:http_error, status, Exception.message(error)}}

      {:error, connection, reason} ->
        Mint.HTTP.close(connection)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp await_upgrade(connection, request_ref, status, headers, deadline) do
    case Mint.HTTP.recv(connection, 0, receive_timeout(deadline)) do
      {:ok, connection, responses} ->
        {status, headers, done?} =
          Enum.reduce(responses, {status, headers, false}, fn
            {:status, ^request_ref, value}, {_status, headers, done?} ->
              {value, headers, done?}

            {:headers, ^request_ref, values}, {status, _headers, done?} ->
              {status, values, done?}

            {:done, ^request_ref}, {status, headers, _done?} ->
              {status, headers, true}

            _response, acc ->
              acc
          end)

        cond do
          done? and is_integer(status) -> {:ok, connection, status, headers}
          remaining(deadline) <= 0 -> {:error, connection, :websocket_connect_timeout}
          true -> await_upgrade(connection, request_ref, status, headers, deadline)
        end

      {:error, connection, reason, _responses} ->
        {:error, connection, reason}
    end
  end

  defp send_request(state, body) do
    payload = body |> Map.put("type", "response.create") |> JSON.encode!()

    case send_frame(state, {:text, payload}) do
      {:ok, state} -> {:ok, state}
      {:error, reason, state} -> {:error, :before_stream, reason, state}
    end
  end

  defp receive_response(state, caller, request_id, monitor, started?, deadline) do
    if remaining(deadline) <= 0 do
      {:error, phase(started?), :receive_timeout, state}
    else
      receive do
        {:cancel, ^caller, ^request_id} ->
          {:error, phase(started?), :cancelled, state}

        {:DOWN, ^monitor, :process, ^caller, reason} ->
          {:error, phase(started?), {:caller_stopped, reason}, state}
      after
        0 -> receive_frames(state, caller, request_id, monitor, started?, deadline)
      end
    end
  end

  defp receive_frames(state, caller, request_id, monitor, started?, deadline) do
    timeout = min(@receive_poll_timeout, receive_timeout(deadline))

    case Mint.WebSocket.recv(state.connection, 0, timeout) do
      {:ok, connection, responses} ->
        on_responses(
          responses,
          %{state | connection: connection},
          caller,
          request_id,
          monitor,
          started?,
          deadline
        )

      {:error, connection, %Mint.TransportError{reason: :timeout}, []} ->
        receive_response(
          %{state | connection: connection},
          caller,
          request_id,
          monitor,
          started?,
          deadline
        )

      {:error, connection, reason, responses} ->
        on_transport_error(
          responses,
          reason,
          %{state | connection: connection},
          caller,
          request_id,
          monitor,
          started?,
          deadline
        )
    end
  end

  defp on_responses(responses, state, caller, request_id, monitor, started?, deadline) do
    deadline = record_activity(caller, request_id, responses, state.receive_timeout, deadline)

    case process_responses(responses, state, caller, request_id, monitor, started?) do
      {:cont, state, started?} ->
        receive_response(state, caller, request_id, monitor, started?, deadline)

      {:done, event, state} ->
        {:ok, event, state}

      {:retry_full, state} ->
        {:error, :previous_response_not_found, state}

      {:error, reason, state, started?} ->
        {:error, phase(started?), reason, state}
    end
  end

  defp on_transport_error(
         responses,
         reason,
         state,
         caller,
         request_id,
         monitor,
         started?,
         deadline
       ) do
    _deadline = record_activity(caller, request_id, responses, state.receive_timeout, deadline)

    case process_responses(responses, state, caller, request_id, monitor, started?) do
      {:done, event, state} ->
        {:ok, event, state}

      {:retry_full, state} ->
        {:error, :previous_response_not_found, state}

      {:cont, state, started?} ->
        {:error, phase(started?), reason, state}

      {:error, frame_reason, state, started?} ->
        {:error, phase(started?), frame_reason, state}
    end
  end

  defp record_activity(_caller, _request_id, [], _timeout, deadline), do: deadline

  defp record_activity(caller, request_id, _responses, timeout, _deadline) do
    send(caller, {:websocket_activity, request_id})
    deadline(timeout)
  end

  defp process_responses(responses, state, caller, request_id, monitor, started?) do
    Enum.reduce_while(responses, {:cont, state, started?}, fn response, acc ->
      case handle_response(response, acc, caller, request_id, monitor) do
        {:cont, state, started?} -> {:cont, {:cont, state, started?}}
        result -> {:halt, result}
      end
    end)
  end

  defp handle_response(
         {:data, request_ref, data},
         {:cont, %{request_ref: request_ref} = state, started?},
         caller,
         request_id,
         monitor
       ) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        state = %{state | websocket: websocket}

        case process_frames(frames, state, caller, request_id, monitor, started?) do
          {:cont, state, started?} -> {:cont, state, started?}
          result -> result
        end

      {:error, websocket, reason} ->
        {:error, reason, %{state | websocket: websocket}, started?}
    end
  end

  defp handle_response(_response, acc, _caller, _request_id, _monitor), do: acc

  defp process_frames(frames, state, caller, request_id, monitor, started?) do
    Enum.reduce_while(frames, {:cont, state, started?}, fn frame, {:cont, state, started?} ->
      case process_frame(frame, state, caller, request_id, monitor, started?) do
        {:cont, state, started?} -> {:cont, {:cont, state, started?}}
        result -> {:halt, result}
      end
    end)
  end

  defp process_frame({:text, text}, state, caller, request_id, monitor, started?) do
    case decode_event(text) do
      {:ok, event} -> process_text_event(event, state, caller, request_id, monitor, started?)
      {:error, reason} -> {:error, reason, state, started?}
    end
  end

  defp process_frame({:binary, data}, state, caller, request_id, monitor, started?)
       when is_binary(data) do
    process_frame({:text, data}, state, caller, request_id, monitor, started?)
  end

  defp process_frame({:ping, payload}, state, _caller, _request_id, _monitor, started?) do
    case send_control(state, {:pong, payload}) do
      {:ok, state} -> {:cont, state, started?}
      {:error, reason, state} -> {:error, reason, state, started?}
    end
  end

  defp process_frame({:pong, _payload}, state, _caller, _request_id, _monitor, started?),
    do: {:cont, state, started?}

  defp process_frame(
         {:close, code, reason},
         state,
         _caller,
         _request_id,
         _monitor,
         started?
       ),
       do: {:error, {:websocket_closed, code, reason}, state, started?}

  defp process_frame({:error, reason}, state, _caller, _request_id, _monitor, started?),
    do: {:error, reason, state, started?}

  defp process_text_event(event, state, caller, request_id, monitor, started?) do
    state = capture_response_id(state, event)

    if previous_response_not_found?(event) and not started? do
      {:retry_full, state}
    else
      terminal? = terminal_event?(event)
      event = if terminal?, do: normalize_terminal_event(event), else: event
      started? = started? or emits_callback?(event)

      case deliver_event(caller, request_id, event, monitor) do
        :ok when terminal? -> {:done, event, state}
        :ok -> {:cont, state, started?}
        {:error, reason} -> {:error, reason, state, started?}
      end
    end
  end

  defp deliver_event(caller, request_id, event, monitor) do
    delivery_id = make_ref()
    send(caller, {:websocket_event, request_id, delivery_id, event})

    receive do
      {:websocket_ack, ^caller, ^request_id, ^delivery_id} -> :ok
      {:cancel, ^caller, ^request_id} -> {:error, :cancelled}
      {:DOWN, ^monitor, :process, ^caller, reason} -> {:error, {:caller_stopped, reason}}
    end
  end

  defp send_control(state, frame), do: send_frame(state, frame)

  defp send_frame(state, frame) do
    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, data} ->
        state = %{state | websocket: websocket}

        case Mint.WebSocket.stream_request_body(state.connection, state.request_ref, data) do
          {:ok, connection} -> {:ok, %{state | connection: connection}}
          {:error, connection, reason} -> {:error, reason, %{state | connection: connection}}
        end

      {:error, websocket, reason} ->
        {:error, reason, %{state | websocket: websocket}}
    end
  end

  defp decode_event(text) do
    case JSON.decode(text) do
      {:ok, %{} = event} -> {:ok, event}
      {:ok, _value} -> {:error, :invalid_websocket_event}
      {:error, _reason} -> {:error, {:invalid_websocket_json, String.slice(text, 0, 512)}}
    end
  end

  defp terminal_event?(%{"type" => type}) do
    type in [
      "response.completed",
      "response.done",
      "response.incomplete",
      "response.failed",
      "error"
    ]
  end

  defp terminal_event?(_event), do: false

  defp normalize_terminal_event(%{"type" => "response.done"} = event),
    do: Map.put(event, "type", "response.completed")

  defp normalize_terminal_event(event), do: event

  defp previous_response_not_found?(event) do
    error = event["error"] || get_in(event, ["response", "error"]) || %{}
    event["code"] == @previous_response_not_found or error["code"] == @previous_response_not_found
  end

  defp emits_callback?(%{"type" => type}) do
    type in [
      "response.output_text.delta",
      "response.refusal.delta",
      "response.reasoning_summary_text.delta",
      "response.function_call_arguments.delta"
    ]
  end

  defp emits_callback?(_event), do: false

  defp update_continuation(state, request_body, terminal_event, true) do
    response = terminal_event["response"] || %{}
    response_id = response["id"] || state.response_id

    if terminal_event["type"] == "response.completed" and
         response["status"] in [nil, "completed"] and is_binary(response_id) and
         response_id != "" do
      continuation = %{
        request_body: request_body,
        response_id: response_id,
        response_items: provider_output(response["output"])
      }

      %{state | continuation: continuation, response_id: nil}
    else
      %{state | continuation: nil, response_id: nil}
    end
  end

  defp update_continuation(state, _request_body, _terminal_event, false),
    do: %{state | continuation: nil, response_id: nil}

  defp capture_response_id(state, %{"response" => %{"id" => response_id}})
       when is_binary(response_id) and response_id != "" do
    %{state | response_id: response_id}
  end

  defp capture_response_id(state, _event), do: state

  defp provider_output(output) when is_list(output) do
    Enum.map(output, fn
      %{"type" => "reasoning"} = item -> Map.delete(item, "content")
      item -> item
    end)
  end

  defp provider_output(_output), do: []

  defp request_path(uri) do
    path = if uri.path in [nil, ""], do: "/", else: uri.path
    if uri.query, do: path <> "?" <> uri.query, else: path
  end

  defp maybe_put_cacerts(opts, :https),
    do: Keyword.put(opts, :cacerts, :public_key.cacerts_get())

  defp maybe_put_cacerts(opts, :http), do: opts

  defp close_connection(%__MODULE__{connection: nil} = state), do: state

  defp close_connection(state) do
    state = close_websocket(state)

    Mint.HTTP.close(state.connection)
    %{state | connection: nil, websocket: nil, request_ref: nil}
  rescue
    _exception -> %{state | connection: nil, websocket: nil, request_ref: nil}
  end

  defp close_websocket(%__MODULE__{websocket: nil} = state), do: state
  defp close_websocket(%__MODULE__{request_ref: nil} = state), do: state

  defp close_websocket(state) do
    case Mint.WebSocket.encode(state.websocket, :close) do
      {:ok, websocket, data} -> stream_close_frame(state, websocket, data)
      _error -> state
    end
  end

  defp stream_close_frame(state, websocket, data) do
    case Mint.WebSocket.stream_request_body(state.connection, state.request_ref, data) do
      {:ok, connection} -> %{state | connection: connection, websocket: websocket}
      _error -> state
    end
  end

  defp schedule_idle(%__MODULE__{idle_timeout: timeout} = state)
       when is_integer(timeout) and timeout > 0 do
    token = make_ref()
    timer = Process.send_after(self(), {:idle_timeout, token}, timeout)
    %{state | idle_timer: {timer, token}}
  end

  defp schedule_idle(state), do: state

  defp cancel_idle(%__MODULE__{idle_timer: nil} = state), do: state

  defp cancel_idle(state) do
    {timer, _token} = state.idle_timer
    Process.cancel_timer(timer)
    %{state | idle_timer: nil}
  end

  defp phase(false), do: :before_stream
  defp phase(true), do: :after_stream

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout) when is_integer(timeout) and timeout > 0, do: now() + timeout
  defp deadline(_timeout), do: now()

  defp receive_timeout(:infinity), do: @receive_poll_timeout
  defp receive_timeout(deadline), do: max(0, deadline - now())
  defp remaining(:infinity), do: 1
  defp remaining(deadline), do: deadline - now()
  defp now, do: System.monotonic_time(:millisecond)
end
