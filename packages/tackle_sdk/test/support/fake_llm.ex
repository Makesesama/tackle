defmodule Tackle.SDK.Test.FakeLLM do
  @moduledoc """
  Deterministic `Tackle.Lib.LLM` adapter for tests.

  The first generation of a turn requests one `echo` tool call; once a tool
  result is present in the conversation it returns a final assistant message.
  This exercises the full ReAct loop (assistant tool call -> tool execution ->
  final response) without any provider or credentials.
  """

  @behaviour Tackle.Lib.LLM

  @impl true
  def adapter_id, do: "fake"

  @impl true
  def models, do: ["echo"]

  @impl true
  def generate(_schema, opts) do
    messages = Keyword.get(opts, :messages, [])

    if Enum.any?(messages, &match?(%{role: :tool}, &1)) do
      {:ok,
       %{
         data: %{"content" => "all done", "tool_calls" => []},
         usage: nil,
         model: "echo"
       }}
    else
      {:ok,
       %{
         data: %{
           "content" => nil,
           "tool_calls" => [
             %{
               "id" => "call_1",
               "name" => "echo",
               "arguments" => %{"text" => "hello"}
             }
           ]
         },
         usage: nil,
         model: "echo"
       }}
    end
  end
end

defmodule Tackle.SDK.Test.SlowLLM do
  @moduledoc """
  `Tackle.Lib.LLM` adapter that sleeps before answering, so tests can cancel a
  turn while the provider call is in flight.
  """

  @behaviour Tackle.Lib.LLM

  @sleep_ms 200

  @impl true
  def adapter_id, do: "slow"

  @impl true
  def models, do: ["sleepy"]

  @impl true
  def generate(_schema, _opts) do
    Process.sleep(@sleep_ms)

    {:ok,
     %{
       data: %{"content" => "finally awake", "tool_calls" => []},
       usage: nil,
       model: "sleepy"
     }}
  end
end

defmodule Tackle.SDK.Test.RecordingLLM do
  @moduledoc """
  `Tackle.Lib.LLM` adapter that reports the generate opts it received to
  `opts[:test_pid]`, so tests can assert host `llm_opts` reach the adapter.
  """

  @behaviour Tackle.Lib.LLM

  @impl true
  def adapter_id, do: "record"

  @impl true
  def models, do: ["opts"]

  @impl true
  def generate(_schema, opts) do
    if pid = Keyword.get(opts, :test_pid), do: send(pid, {:generate_opts, opts})

    {:ok,
     %{
       data: %{"content" => "recorded", "tool_calls" => []},
       usage: nil,
       model: "opts"
     }}
  end
end

defmodule Tackle.SDK.Test.EchoTool do
  @moduledoc "Server-side test tool that echoes its `text` argument."

  @behaviour Tackle.Lib.Tool

  @impl true
  def name, do: "echo"

  @impl true
  def description, do: "Echoes the given text back to the model."

  @impl true
  def parameters_schema do
    [text: [type: :string, required: true, description: "Text to echo"]]
  end

  @impl true
  def execute(%{"text" => text}, _context), do: {:ok, text}
  def execute(_args, _context), do: {:error, :missing_text}
end
