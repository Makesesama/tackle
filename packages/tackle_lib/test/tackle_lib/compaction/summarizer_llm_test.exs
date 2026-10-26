defmodule Tackle.Lib.Compaction.Summarizer.LLMTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Compaction.Request
  alias Tackle.Lib.Compaction.Summarizer
  alias Tackle.Lib.LLM
  alias Tackle.Lib.Message

  defmodule CaptureAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "capture"

    @impl true
    def models, do: ["model"]

    @impl true
    def generate(_schema, opts) do
      send(self(), {:summary_opts, opts})
      {:ok, %{data: %{"content" => "summary"}, usage: nil, model: "model"}}
    end
  end

  test "host llm_opts override tuning defaults but not the summary request" do
    {:ok, selection} = LLM.select([CaptureAdapter], "capture/model")

    request = %Request{
      messages: [Message.user("hello")],
      selection: selection,
      summary_max_tokens: 500
    }

    assert {:ok, %{content: "summary"}} =
             Summarizer.LLM.summarize(request,
               llm_opts: [temperature: 0.7, tool_choice: "auto", max_tokens: 9_999]
             )

    assert_receive {:summary_opts, opts}
    assert Keyword.get_values(opts, :temperature) == [0.7]
    assert Keyword.get_values(opts, :tool_choice) == ["none"]
    assert Keyword.get_values(opts, :max_tokens) == [500]
    assert Keyword.get_values(opts, :max_output_tokens) == [500]
  end
end
