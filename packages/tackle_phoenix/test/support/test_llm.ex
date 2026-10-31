defmodule Tackle.Phoenix.Test.LLM do
  @moduledoc false

  # A `Tackle.Lib.LLM` adapter the test drives step by step. Each call tells
  # `opts[:test_pid]` `{:model_call, pid}` and then streams what the test sends
  # that pid: `{:delta, text}` streams answer text, `{:finish, content}` ends
  # the call with that answer. A cancelled turn ends the call with an error.

  @behaviour Tackle.Lib.LLM

  alias Tackle.Lib.Cancellation

  @impl true
  def adapter_id, do: "test"

  @impl true
  def models, do: ["chat"]

  @impl true
  def model_info(_model), do: %{context_window: 100_000, max_output_tokens: 1_000}

  @impl true
  def stream(_schema, opts, callback) do
    send(Keyword.fetch!(opts, :test_pid), {:model_call, self()})
    await(opts, callback)
  end

  @impl true
  def generate(schema, opts), do: stream(schema, opts, fn _event -> :ok end)

  defp await(opts, callback) do
    receive do
      {:delta, text} ->
        callback.(%{type: :text_delta, text: text})
        await(opts, callback)

      {:finish, content} ->
        {:ok,
         %{
           data: %{"content" => content, "tool_calls" => []},
           usage: %{input_tokens: 10, output_tokens: 5},
           model: Keyword.fetch!(opts, :model)
         }}
    after
      5 ->
        if Cancellation.cancelled?(opts[:cancellation_signal]),
          do: {:error, :cancelled},
          else: await(opts, callback)
    end
  end
end
