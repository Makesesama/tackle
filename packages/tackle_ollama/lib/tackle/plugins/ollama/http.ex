defmodule Tackle.Plugins.Ollama.HTTP do
  @moduledoc false

  @type stream_callback ::
          (binary(), Req.Response.t(), term() -> {:cont, term()} | {:halt, term()})

  @doc "Streams a request with the Req.stream/4 accumulator contract."
  @spec stream(keyword(), term(), stream_callback(), keyword()) ::
          {:ok, Req.Response.t() | map()} | {:error, term()}
  def stream(request_options, initial_acc, callback, opts \\ []) do
    result =
      case Keyword.fetch(opts, :stream) do
        {:ok, stream_fun} ->
          stream_fun.(request_options, initial_acc, callback)

        :error ->
          stream_request(request_options, initial_acc, callback, opts)
      end

    normalize_stream_result(result)
  rescue
    exception -> {:error, {:request_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:request_failed, {kind, reason}}}
  end

  @cancel_poll_ms 50

  @doc """
  Sends a non-streaming request and returns the whole response.

  `opts[:request]` replaces `Req.request/1` (tests inject it). With a
  `:cancellation_signal` the request runs in a linked task that is killed once
  the signal is cancelled, returning `{:error, :cancelled}`.
  """
  @spec request(keyword(), keyword()) :: {:ok, Req.Response.t() | map()} | {:error, term()}
  def request(request_options, opts \\ []) do
    request_fun = Keyword.get(opts, :request, &Req.request/1)

    case Keyword.get(opts, :cancellation_signal) do
      nil -> send_request(request_fun, request_options)
      signal -> cancellable_request(request_fun, request_options, signal)
    end
  end

  defp cancellable_request(request_fun, request_options, signal) do
    task = Task.async(fn -> send_request(request_fun, request_options) end)
    await_unless_cancelled(task, signal)
  end

  defp await_unless_cancelled(task, signal) do
    case Task.yield(task, @cancel_poll_ms) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, {:request_failed, {:exit, reason}}}

      nil ->
        if Tackle.Lib.Cancellation.cancelled?(signal) do
          Task.shutdown(task, :brutal_kill)
          {:error, :cancelled}
        else
          await_unless_cancelled(task, signal)
        end
    end
  end

  defp send_request(request_fun, request_options) do
    case request_fun.(request_options) do
      {:ok, %{status: status} = response} when is_integer(status) -> {:ok, response}
      {:error, reason} -> {:error, {:request_failed, reason}}
      other -> {:error, {:invalid_http_response, other}}
    end
  rescue
    exception -> {:error, {:request_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:request_failed, {kind, reason}}}
  end

  defp stream_request(request_options, initial_acc, callback, opts) do
    case Keyword.fetch(opts, :request) do
      {:ok, request_fun} ->
        stream_with_test_request(request_fun, request_options, initial_acc, callback)

      :error ->
        Req.stream(request_options, initial_acc, callback)
    end
  end

  defp stream_with_test_request(request_fun, request_options, initial_acc, callback) do
    into = fn {:data, chunk}, {request, response} ->
      acc = if response.body in [nil, ""], do: initial_acc, else: response.body

      case callback.(chunk, response, acc) do
        {:cont, acc} -> {:cont, {request, %{response | body: acc}}}
        {:halt, acc} -> {:halt, {request, %{response | body: acc}}}
      end
    end

    request_fun.(Keyword.put(request_options, :into, into))
  end

  defp normalize_stream_result({:ok, %Req.Response{} = response, acc}),
    do: {:ok, %{response | body: acc}}

  defp normalize_stream_result({:ok, %{status: _status} = response, acc}),
    do: {:ok, Map.put(response, :body, acc)}

  defp normalize_stream_result({:ok, %Req.Response{} = response}), do: {:ok, response}
  defp normalize_stream_result({:ok, %{status: _status} = response}), do: {:ok, response}

  defp normalize_stream_result({:error, reason, _response, _acc}),
    do: {:error, {:request_failed, reason}}

  defp normalize_stream_result({:error, reason}), do: {:error, {:request_failed, reason}}
  defp normalize_stream_result(other), do: {:error, {:invalid_http_response, other}}

  @spec error_body(term()) :: term()
  def error_body(%{} = body), do: body
  def error_body(body) when is_binary(body), do: String.slice(body, 0, 4_096)
  def error_body(body), do: inspect(body, limit: 20, printable_limit: 4_096)
end
