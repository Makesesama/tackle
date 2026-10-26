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

  defmodule ScriptedAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "scripted"

    @impl true
    def models, do: ["model"]

    @impl true
    def generate(_schema, _opts),
      do: {:ok, %{data: Process.get(:summary_data), usage: nil, model: "model"}}
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
    refute Keyword.has_key?(opts, :max_output_tokens)
    refute Keyword.has_key?(opts, :native_tools)
    refute Keyword.has_key?(opts, :strict_schema)
  end

  test "a summary with tool calls or without content is rejected" do
    {:ok, selection} = LLM.select([ScriptedAdapter], "scripted/model")
    request = %Request{messages: [Message.user("hello")], selection: selection}

    for {data, reason} <- [
          {%{"content" => "s", "tool_calls" => [%{"id" => "c", "name" => "read"}]},
           :summary_tool_calls},
          {%{"content" => ""}, :empty_summary},
          {%{}, :empty_summary}
        ] do
      Process.put(:summary_data, data)
      assert Summarizer.LLM.summarize(request) == {:error, reason}
    end
  end

  test "a malformed adapter result is an invalid response error" do
    {:ok, selection} = LLM.select([ScriptedAdapter], "scripted/model")
    request = %Request{messages: [Message.user("hello")], selection: selection}
    Process.put(:summary_data, %{"content" => 42})

    assert {:error, %LLM.Error{kind: :invalid_response}} = Summarizer.LLM.summarize(request)
  end
end
