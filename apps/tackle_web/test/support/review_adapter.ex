defmodule Tackle.Web.ReviewAdapter do
  @moduledoc false
  @behaviour Tackle.Lib.LLM

  alias Tackle.Lib.Cancellation

  @impl true
  def adapter_id, do: "scripted"
  @impl true
  def models, do: ["detector", "verifier", "scorer"]
  @impl true
  def model_info(_model), do: %{context_window: 100_000, max_output_tokens: 1_000}

  @impl true
  def stream(schema, opts, callback) do
    callback.(%{type: :text_delta, text: "reviewing"})
    generate(schema, opts)
  end

  @impl true
  def generate(schema, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:model_call, self(), schema, opts})
    Keyword.fetch!(opts, :script).(schema, opts)
  end

  def response(data, opts) do
    {:ok,
     %{
       data: data,
       usage: %{input_tokens: 10, output_tokens: 5},
       model: Keyword.fetch!(opts, :model)
     }}
  end

  def answer(opts), do: response(%{"content" => "done", "tool_calls" => []}, opts)

  def report(name, arguments, opts) do
    response(
      %{
        "content" => nil,
        "tool_calls" => [
          %{
            "id" => "call-#{System.unique_integer([:positive])}",
            "name" => name,
            "arguments" => arguments
          }
        ]
      },
      opts
    )
  end

  def prompt(opts) do
    Enum.find_value(opts[:messages], "", fn
      %{role: :user, content: content} -> content
      _message -> nil
    end)
  end

  def block(_schema, opts) do
    if Cancellation.cancelled?(opts[:cancellation_signal]) do
      {:error, :cancelled}
    else
      Process.sleep(5)
      block(nil, opts)
    end
  end
end
