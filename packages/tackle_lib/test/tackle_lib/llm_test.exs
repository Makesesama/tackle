defmodule Tackle.Lib.LLMTest do
  use ExUnit.Case, async: false

  alias Tackle.Lib.Event
  alias Tackle.Lib.LLM
  alias Tackle.Lib.Usage

  defmodule TestAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def generate(_schema, _opts) do
      {:ok,
       %{
         data: %{"content" => "ok"},
         usage: %{prompt_tokens: 4, completion_tokens: 6},
         model: "test/model",
         provider: :test_provider
       }}
    end

    @impl true
    def stream(_schema, _opts, event_callback) do
      event_callback.(%{type: :text_delta, text: "hel"})
      event_callback.(%{type: :text_delta, text: "lo"})

      {:ok,
       %{
         data: %{"content" => "hello"},
         usage: %{prompt_tokens: 3, completion_tokens: 2},
         model: "test/model",
         provider: :test_provider
       }}
    end
  end

  setup do
    previous = Application.get_env(:tackle_lib, :llm)
    Application.put_env(:tackle_lib, :llm, TestAdapter)

    on_exit(fn ->
      if previous do
        Application.put_env(:tackle_lib, :llm, previous)
      else
        Application.delete_env(:tackle_lib, :llm)
      end
    end)
  end

  test "normalizes adapter usage maps" do
    assert {:ok, response} = LLM.generate([], [])
    assert response.data == %{"content" => "ok"}
    assert %Usage{input_tokens: 4, output_tokens: 6, total_tokens: 10} = response.usage
    assert response.usage.model == "test/model"
    assert response.usage.provider == :test_provider
  end

  test "normalizes adapter stream events into Tackle.Lib events" do
    test_pid = self()

    assert {:ok, response} =
             LLM.stream([], [], fn event -> send(test_pid, {:event, event}) end)

    assert response.data == %{"content" => "hello"}
    assert %Usage{input_tokens: 3, output_tokens: 2, total_tokens: 5} = response.usage

    assert_receive {:event, %Event{type: :message_delta, data: %{delta: "hel"}}}
    assert_receive {:event, %Event{type: :message_delta, data: %{delta: "lo"}}}
  end
end
