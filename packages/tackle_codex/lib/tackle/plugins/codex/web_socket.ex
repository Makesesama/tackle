defmodule Tackle.Plugins.Codex.WebSocket do
  @moduledoc false

  alias Tackle.Lib.Cancellation
  alias Tackle.Plugins.Codex.SSE
  alias Tackle.Plugins.Codex.WebSocket.Connection

  @registry Tackle.Plugins.Codex.WebSocket.Registry
  @supervisor Tackle.Plugins.Codex.WebSocket.Supervisor
  @poll_interval 50

  @type transport :: :websocket | :websocket_cached | :auto

  @spec request(map(), keyword(), [{binary(), binary()}], (map() -> any())) ::
          {:ok, %{status: 200, body: SSE.t()}} | {:error, term()}
  def request(body, opts, headers, event_callback)
      when is_map(body) and is_list(opts) and is_list(headers) and
             is_function(event_callback, 1) do
    with {:ok, transport} <- transport(opts),
         {:ok, url} <- websocket_url(Keyword.fetch!(opts, :responses_url)),
         {:ok, pid, temporary?} <- connection(url, headers, opts) do
      ref = make_ref()
      send(pid, {:request, self(), ref, body, transport in [:websocket_cached, :auto]})

      result =
        await_response(
          pid,
          ref,
          SSE.new(),
          event_callback,
          Keyword.get(opts, :cancellation_signal),
          Keyword.get(opts, :receive_timeout, 120_000),
          deadline(Keyword.get(opts, :receive_timeout, 120_000)),
          false
        )

      if temporary? or match?({:error, _reason}, result), do: terminate_connection(pid)
      drain_protocol_messages(ref)
      result
    end
  rescue
    KeyError -> {:error, {:websocket_transport_failed, :before_stream, :responses_url_required}}
  end

  @doc false
  @spec continuation_request(map(), map() | nil) :: {map(), :full | :delta}
  def continuation_request(body, nil), do: {body, :full}

  def continuation_request(body, continuation) when is_map(body) and is_map(continuation) do
    with previous_response_id when is_binary(previous_response_id) and previous_response_id != "" <-
           continuation[:response_id],
         previous_body when is_map(previous_body) <- continuation[:request_body],
         response_items when is_list(response_items) <- continuation[:response_items],
         true <- request_options(previous_body) == request_options(body),
         previous_input when is_list(previous_input) <- previous_body["input"] || [],
         current_input when is_list(current_input) <- body["input"] || [],
         baseline <- previous_input ++ response_items,
         true <- length(current_input) >= length(baseline),
         true <- Enum.take(current_input, length(baseline)) == baseline do
      request =
        body
        |> Map.put("previous_response_id", previous_response_id)
        |> Map.put("input", Enum.drop(current_input, length(baseline)))

      {request, :delta}
    else
      _reason -> {body, :full}
    end
  end

  @spec close_session(binary()) :: :ok
  def close_session(session_id) when is_binary(session_id) do
    session_id
    |> session_connections()
    |> Enum.each(&terminate_connection/1)

    await_session_closed(session_id, now() + 100)
  rescue
    ArgumentError -> :ok
  end

  defp session_connections(session_id) do
    Registry.select(@registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.flat_map(fn
      {{:session, ^session_id, _connection_key}, pid} -> [pid]
      _entry -> []
    end)
  end

  defp await_session_closed(session_id, deadline) do
    cond do
      session_connections(session_id) == [] ->
        :ok

      now() >= deadline ->
        :ok

      true ->
        Process.sleep(1)
        await_session_closed(session_id, deadline)
    end
  end

  defp request_options(body) do
    Map.drop(body, ["input", "previous_response_id"])
  end

  defp connection(url, headers, opts) do
    case Keyword.get(opts, :session_id) do
      session_id when is_binary(session_id) and session_id != "" ->
        account_id = header(headers, "chatgpt-account-id")
        authorization = header(headers, "authorization")
        token_hash = if authorization, do: :crypto.hash(:sha256, authorization)

        key = {:session, session_id, {url, account_id, token_hash}}
        start_connection(key, url, headers, opts, false)

      _session_id ->
        start_connection({:request, make_ref()}, url, headers, opts, true)
    end
  end

  defp start_connection(key, url, headers, opts, temporary?) do
    lease = :atomics.new(1, signed: false)
    :atomics.put(lease, 1, 1)

    child_opts = connection_options(key, url, headers, opts, lease)

    case DynamicSupervisor.start_child(@supervisor, {Connection, child_opts}) do
      {:ok, pid} ->
        {:ok, pid, temporary?}

      {:error, {:already_started, pid}} ->
        checkout_existing(pid, key, url, headers, opts, temporary?)

      {:error, reason} ->
        {:error, {:websocket_transport_failed, :before_stream, reason}}
    end
  end

  defp checkout_existing(pid, key, url, headers, opts, temporary?) do
    case Registry.lookup(@registry, key) do
      [{^pid, lease}] ->
        case :atomics.compare_exchange(lease, 1, 0, 1) do
          :ok -> {:ok, pid, temporary?}
          _busy -> start_connection({:request, make_ref()}, url, headers, opts, true)
        end

      _entries ->
        start_connection({:request, make_ref()}, url, headers, opts, true)
    end
  end

  defp connection_options(key, url, headers, opts, lease) do
    [
      key: key,
      lease: lease,
      url: url,
      headers: headers,
      connect_timeout: Keyword.get(opts, :websocket_connect_timeout, 15_000),
      receive_timeout: Keyword.get(opts, :receive_timeout, 120_000),
      idle_timeout: Keyword.get(opts, :websocket_idle_timeout, 5 * 60_000)
    ]
  end

  defp await_response(pid, ref, parser, callback, signal, timeout, deadline, started?) do
    cond do
      Cancellation.cancelled?(signal) ->
        cancel_and_wait(pid, ref)
        {:error, :cancelled}

      remaining(deadline) <= 0 ->
        cancel_and_wait(pid, ref)
        {:error, {:websocket_transport_failed, phase(started?), :receive_timeout}}

      true ->
        receive do
          {:websocket_event, ^ref, delivery_id, event} ->
            parser = SSE.push_event(parser, event, callback)
            started? = started? or starts_stream?(event)

            if Cancellation.cancelled?(signal) do
              cancel_and_wait(pid, ref)
              {:error, :cancelled}
            else
              send(pid, {:websocket_ack, self(), ref, delivery_id})

              await_response(
                pid,
                ref,
                parser,
                callback,
                signal,
                timeout,
                deadline(timeout),
                started?
              )
            end

          {:websocket_activity, ^ref} ->
            await_response(
              pid,
              ref,
              parser,
              callback,
              signal,
              timeout,
              deadline(timeout),
              started?
            )

          {:websocket_done, ^ref} ->
            {:ok, %{status: 200, body: parser}}

          {:websocket_error, ^ref, phase, reason} ->
            {:error, {:websocket_transport_failed, phase, reason}}
        after
          min(@poll_interval, remaining(deadline)) ->
            if Process.alive?(pid) do
              await_response(pid, ref, parser, callback, signal, timeout, deadline, started?)
            else
              {:error, {:websocket_transport_failed, phase(started?), :connection_stopped}}
            end
        end
    end
  rescue
    exception ->
      cancel_and_wait(pid, ref)
      {:error, {:websocket_transport_failed, :after_stream, Exception.message(exception)}}
  catch
    kind, reason ->
      cancel_and_wait(pid, ref)
      {:error, {:websocket_transport_failed, :after_stream, {kind, reason}}}
  end

  defp cancel_and_wait(pid, ref) do
    send(pid, {:cancel, self(), ref})

    receive do
      {:websocket_error, ^ref, _phase, _reason} -> :ok
      {:websocket_done, ^ref} -> :ok
    after
      50 -> :ok
    end
  end

  defp terminate_connection(pid) do
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      1_000 -> Process.demonitor(monitor, [:flush])
    end

    await_unregistered(pid, now() + 100)
  end

  defp await_unregistered(pid, deadline) do
    cond do
      Registry.keys(@registry, pid) == [] ->
        :ok

      now() >= deadline ->
        :ok

      true ->
        Process.sleep(1)
        await_unregistered(pid, deadline)
    end
  rescue
    ArgumentError -> :ok
  end

  defp drain_protocol_messages(ref) do
    receive do
      {:websocket_activity, ^ref} -> drain_protocol_messages(ref)
      {:websocket_event, ^ref, _delivery_id, _event} -> drain_protocol_messages(ref)
      {:websocket_done, ^ref} -> drain_protocol_messages(ref)
      {:websocket_error, ^ref, _phase, _reason} -> drain_protocol_messages(ref)
    after
      0 -> :ok
    end
  end

  defp header(headers, wanted_name) do
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(name) == wanted_name, do: value
    end)
  end

  defp starts_stream?(%{"type" => type}) do
    type in [
      "response.output_text.delta",
      "response.refusal.delta",
      "response.reasoning_summary_text.delta",
      "response.function_call_arguments.delta",
      "response.completed",
      "response.incomplete",
      "response.failed",
      "error"
    ]
  end

  defp starts_stream?(_event), do: false

  defp phase(false), do: :before_stream
  defp phase(true), do: :after_stream

  defp transport(opts) do
    case Keyword.get(opts, :transport, :auto) do
      transport when transport in [:websocket, :websocket_cached, :auto] -> {:ok, transport}
      transport -> {:error, {:invalid_transport, transport}}
    end
  end

  defp websocket_url(url) do
    uri = URI.parse(url)

    case uri.scheme do
      "https" -> {:ok, URI.to_string(%{uri | scheme: "wss"})}
      "http" -> {:ok, URI.to_string(%{uri | scheme: "ws"})}
      "wss" -> {:ok, url}
      "ws" -> {:ok, url}
      scheme -> {:error, {:invalid_websocket_scheme, scheme}}
    end
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout) when is_integer(timeout) and timeout > 0, do: now() + timeout
  defp deadline(_timeout), do: now()

  defp remaining(:infinity), do: @poll_interval
  defp remaining(deadline), do: max(0, deadline - now())
  defp now, do: System.monotonic_time(:millisecond)
end
