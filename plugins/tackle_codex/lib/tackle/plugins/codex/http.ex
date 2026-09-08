defmodule Tackle.Plugins.Codex.HTTP do
  @moduledoc false

  @type request_fun :: (keyword() -> {:ok, Req.Response.t()} | {:error, term()})

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
