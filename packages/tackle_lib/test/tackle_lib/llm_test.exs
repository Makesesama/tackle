defmodule Tackle.Lib.LLMTest do
  use ExUnit.Case, async: false

  alias Tackle.Lib.Event
  alias Tackle.Lib.LLM
  alias Tackle.Lib.LLM.Selection
  alias Tackle.Lib.State
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

  defmodule SelectableAdapterA do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "provider-a"

    @impl true
    def models, do: ["shared", "family/nested"]

    @impl true
    def generate(_schema, opts) do
      model = Keyword.fetch!(opts, :model)

      {:ok,
       %{
         data: %{"content" => "provider-a:#{model}"},
         usage: nil,
         model: model,
         provider: adapter_id()
       }}
    end
  end

  defmodule SelectableAdapterB do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "provider-b"

    @impl true
    def models, do: ["shared"]

    @impl true
    def generate(_schema, opts) do
      model = Keyword.fetch!(opts, :model)

      {:ok,
       %{
         data: %{"content" => "provider-b:#{model}"},
         usage: nil,
         model: model,
         provider: adapter_id()
       }}
    end
  end

  defmodule DuplicateAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "provider-a"

    @impl true
    def models, do: ["other"]

    @impl true
    def generate(_schema, _opts), do: {:error, :not_used}
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

  describe "select/2" do
    test "resolves a canonical model reference" do
      assert {:ok,
              %Selection{
                adapter: SelectableAdapterA,
                adapter_id: "provider-a",
                model: "shared",
                ref: "provider-a/shared"
              }} = LLM.select([SelectableAdapterA, SelectableAdapterB], "provider-a/shared")
    end

    test "splits only the first slash in a model reference" do
      assert {:ok, %Selection{model: "family/nested"}} =
               LLM.select([SelectableAdapterA], "provider-a/family/nested")
    end

    test "rejects malformed and unknown model references" do
      assert {:error, {:invalid_model_ref, "Provider A/shared"}} =
               LLM.select([SelectableAdapterA], "Provider A/shared")

      assert {:error, {:unknown_adapter, "missing"}} =
               LLM.select([SelectableAdapterA], "missing/shared")

      assert {:error, {:unknown_model, "provider-a/missing"}} =
               LLM.select([SelectableAdapterA], "provider-a/missing")
    end

    test "rejects duplicate adapter ids" do
      assert {:error, {:duplicate_adapter_id, "provider-a"}} =
               LLM.select([SelectableAdapterA, DuplicateAdapter], "provider-a/shared")
    end

    test "requires selection metadata without breaking legacy default adapters" do
      assert {:error, {:invalid_adapter, TestAdapter, {:missing_callback, {:adapter_id, 0}}}} =
               LLM.select([TestAdapter], "test/model")

      assert LLM.adapter() == TestAdapter
    end

    test "separate states can use different selected adapters concurrently" do
      {:ok, selection_a} = LLM.select([SelectableAdapterA], "provider-a/shared")
      {:ok, selection_b} = LLM.select([SelectableAdapterB], "provider-b/shared")

      task_a = Task.async(fn -> Tackle.Lib.run(State.new(llm: selection_a), "hello") end)
      task_b = Task.async(fn -> Tackle.Lib.run(State.new(llm: selection_b), "hello") end)

      assert {:ok, state_a} = Task.await(task_a)
      assert {:ok, state_b} = Task.await(task_b)
      assert Tackle.Lib.last_answer(state_a) == "provider-a:shared"
      assert Tackle.Lib.last_answer(state_b) == "provider-b:shared"
    end
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
