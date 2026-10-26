defmodule Tackle.Lib.Loop.ResponseSchemaTest do
  # Not async: it sets application environment the loop must ignore.
  use ExUnit.Case, async: false

  alias Tackle.Lib.Loop
  alias Tackle.Lib.State
  alias Tackle.Lib.TestLLM

  # A renderer like the removed `Tackle.Lib.PromptRenderer` callbacks, which
  # asked for a structured response on every request.
  defmodule SchemaRenderer do
    def render_tools(_tools, _opts), do: ""
    def render_response_format(_opts), do: ""
    def response_schema(_opts), do: [answer: [type: :string]]
  end

  defmodule SchemaCapturingAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def generate(schema, _opts) do
      send(Process.get(:test_pid), {:schema, schema})
      {:ok, %{data: %{"content" => "plain answer"}, usage: nil, model: "test/model"}}
    end
  end

  setup do
    previous = Application.get_env(:tackle_lib, :prompt_renderer)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tackle_lib, :prompt_renderer, previous),
        else: Application.delete_env(:tackle_lib, :prompt_renderer)
    end)
  end

  test "a loop turn requests no structured response, whatever the application environment" do
    # A schema would turn the chat answer into a parsed object without
    # "content", which the loop treats as an empty response.
    Application.put_env(:tackle_lib, :prompt_renderer, SchemaRenderer)
    Process.put(:test_pid, self())

    state = State.new(llm: TestLLM.selection(SchemaCapturingAdapter))

    assert {:ok, state} = Loop.run(state, "hello")
    assert_receive {:schema, nil}
    assert Tackle.Lib.last_answer(state) == "plain answer"
  end
end
