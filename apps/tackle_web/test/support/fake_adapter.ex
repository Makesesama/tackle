defmodule Tackle.Web.FakeAdapter do
  @moduledoc """
  Deterministic `Tackle.Lib.LLM` adapter for tests.

  Tests must not need provider credentials or a live model, so the assistant is
  pointed at this adapter instead. It answers from the conversation it is given,
  which is enough to prove the wiring: that the question reached the loop, that
  the answer came back through the Runner, and that the tools ran in the pull
  request's checkout.

  It answers in three shapes:

    * `Echo: ...` — the question was passed through unchanged.
    * `Read: ...` — the question asked for a file and the tool returned its
      contents, so the agent read the checkout.
    * a `read` tool call — the question mentioned `read <path>` and the file has
      not been read yet this turn.

  `Tackle.Lib` falls back to `generate/2` when an adapter does not implement
  `stream/3`, so this adapter needs no streaming machinery.

  It offers two models so tests can prove a conversation changes model without
  changing provider; both answer the same way.
  """

  @behaviour Tackle.Lib.LLM

  @adapter_id "fake"
  @models ["echo", "echo-2"]
  @read_request ~r/read (\S+)/

  @impl true
  def adapter_id, do: @adapter_id

  @impl true
  def models, do: @models

  @impl true
  def model_info(_model), do: nil

  @impl true
  def generate(_schema, opts) do
    messages = Keyword.get(opts, :messages, [])

    case read_request(messages) do
      nil -> reply("Echo: #{user_text(messages)}")
      path -> if read?(messages), do: reply("Read: #{tool_text(messages)}"), else: read_call(path)
    end
  end

  defp reply(content) do
    {:ok, %{data: %{"content" => content, "tool_calls" => []}, usage: nil, model: "echo"}}
  end

  defp read_call(path) do
    call = %{id: "fake-read-1", name: "read", arguments: %{"path" => path}}

    {:ok, %{data: %{"content" => nil, "tool_calls" => [call]}, usage: nil, model: "echo"}}
  end

  defp read_request(messages) do
    case user_text(messages) do
      nil ->
        nil

      text ->
        case Regex.run(@read_request, text) do
          [_all, path] -> path
          nil -> nil
        end
    end
  end

  defp read?(messages) do
    messages
    |> Enum.reverse()
    |> Enum.take_while(&(role(&1) != :user))
    |> Enum.any?(&(role(&1) == :tool))
  end

  defp user_text(messages) do
    messages |> Enum.reverse() |> Enum.find_value(&if(role(&1) == :user, do: content(&1)))
  end

  defp tool_text(messages) do
    messages |> Enum.reverse() |> Enum.find_value(&if(role(&1) == :tool, do: content(&1)))
  end

  defp role(message) when is_map(message), do: Map.get(message, :role, Map.get(message, "role"))
  defp role(_message), do: nil

  defp content(message) do
    case Map.get(message, :content, Map.get(message, "content")) do
      text when is_binary(text) -> text
      _other -> nil
    end
  end
end
