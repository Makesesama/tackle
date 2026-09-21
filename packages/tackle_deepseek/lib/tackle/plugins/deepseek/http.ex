defmodule Tackle.Plugins.DeepSeek.HTTP do
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

  @doc "Performs one non-streaming request."
  @spec request(keyword(), keyword()) :: {:ok, Req.Response.t() | map()} | {:error, term()}
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

  @doc "Decodes a decoded-or-encoded JSON object body."
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
end
