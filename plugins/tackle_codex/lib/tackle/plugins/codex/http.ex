defmodule Tackle.Plugins.Codex.HTTP do
  @moduledoc false

  @type request_fun :: (keyword() -> {:ok, Req.Response.t()} | {:error, term()})
  @type stream_callback ::
          (binary(), Req.Response.t(), term() -> {:cont, term()} | {:halt, term()})
  @type stream_fun ::
          (keyword(), term(), stream_callback() ->
             {:ok, Req.Response.t(), term()}
             | {:error, term(), Req.Response.t(), term()})

  @spec request(keyword(), keyword()) :: {:ok, Req.Response.t()} | {:error, term()}
  def request(request_options, opts \\ []) do
    request_fun = Keyword.get(opts, :request, &Req.request/1)

    case request_fun.(request_options) do
      {:ok, %Req.Response{} = response} -> {:ok, response}
      {:ok, %{status: _status, body: _body} = response} -> {:ok, response}
      {:error, reason} -> {:error, {:request_failed, reason}}
      other -> {:error, {:invalid_http_response, other}}
    end
  rescue
    exception -> {:error, {:request_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:request_failed, {kind, reason}}}
  end

  @doc "Streams a request with the Req.stream/4 accumulator contract."
  @spec stream(keyword(), term(), stream_callback(), keyword()) ::
          {:ok, Req.Response.t() | map()} | {:error, term()}
  def stream(request_options, initial_acc, callback, opts \\ []) do
    callback = preserve_error_body(callback)

    result =
      case Keyword.fetch(opts, :stream) do
        {:ok, stream_fun} ->
          stream_fun.(request_options, initial_acc, callback)

        :error ->
          stream_request(request_options, initial_acc, callback, opts)
      end

    normalize_stream_result(result, initial_acc)
  rescue
    exception -> {:error, {:request_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:request_failed, {kind, reason}}}
  end

  defp stream_request(request_options, initial_acc, callback, opts) do
    case Keyword.fetch(opts, :request) do
      {:ok, request_fun} ->
        stream_with_legacy_test_request(
          request_fun,
          request_options,
          initial_acc,
          callback
        )

      :error ->
        Req.stream(request_options, initial_acc, callback)
    end
  end

  # Existing adapter tests inject a request function that emulates Req's former
  # `into` callback. Keep that seam isolated from production, which always uses
  # Req.stream/4 and therefore emits no deprecation warning.
  defp stream_with_legacy_test_request(request_fun, request_options, initial_acc, callback) do
    into = fn {:data, chunk}, {request, response} ->
      acc = if response.body in [nil, ""], do: initial_acc, else: response.body

      case callback.(chunk, response, acc) do
        {:cont, acc} -> {:cont, {request, %{response | body: acc}}}
        {:halt, acc} -> {:halt, {request, %{response | body: acc}}}
      end
    end

    request_fun.(Keyword.put(request_options, :into, into))
  end

  defp preserve_error_body(callback) do
    fn chunk, response, acc ->
      case response do
        %{status: status} when is_integer(status) and status not in 200..299 ->
          {:cont, append_error_body(acc, chunk)}

        _response ->
          callback.(chunk, response, acc)
      end
    end
  end

  defp append_error_body({:http_error_body, body}, chunk),
    do: {:http_error_body, String.slice(body <> chunk, 0, 4_096)}

  defp append_error_body(_acc, chunk),
    do: {:http_error_body, String.slice(chunk, 0, 4_096)}

  defp normalize_stream_result({:ok, %Req.Response{} = response, acc}, initial_acc),
    do: {:ok, %{response | body: stream_body(response.status, acc, initial_acc)}}

  defp normalize_stream_result({:ok, %{status: status} = response, acc}, initial_acc),
    do: {:ok, Map.put(response, :body, stream_body(status, acc, initial_acc))}

  defp normalize_stream_result({:ok, %Req.Response{} = response}, initial_acc),
    do: {:ok, %{response | body: stream_body(response.status, response.body, initial_acc)}}

  defp normalize_stream_result(
         {:ok, %{status: status, body: body} = response},
         initial_acc
       ),
       do: {:ok, Map.put(response, :body, stream_body(status, body, initial_acc))}

  defp normalize_stream_result({:error, reason, _response, _acc}, _initial_acc),
    do: {:error, {:request_failed, reason}}

  defp normalize_stream_result({:error, reason}, _initial_acc),
    do: {:error, {:request_failed, reason}}

  defp normalize_stream_result(other, _initial_acc),
    do: {:error, {:invalid_http_response, other}}

  defp stream_body(_status, {:http_error_body, body}, _initial_acc), do: body

  defp stream_body(status, body, initial_acc)
       when is_integer(status) and status not in 200..299 and body == initial_acc,
       do: ""

  defp stream_body(_status, body, _initial_acc), do: body

  @spec decode_json(term()) :: {:ok, map()} | {:error, term()}
  def decode_json(%{} = body), do: {:ok, body}

  def decode_json(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      {:ok, _decoded} -> {:error, :expected_json_object}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  def decode_json(_body), do: {:error, :invalid_json}

  @spec error_body(term()) :: term()
  def error_body(%{} = body), do: body
  def error_body(body) when is_binary(body), do: String.slice(body, 0, 4_096)
  def error_body(body), do: inspect(body, limit: 20, printable_limit: 4_096)
end
