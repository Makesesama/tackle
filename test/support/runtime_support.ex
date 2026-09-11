defmodule Tackle.Test.BlockingTool do
  @moduledoc false

  @behaviour Tackle.Lib.Tool

  @impl true
  def name, do: "blocking"

  @impl true
  def description, do: "Blocks until the test process releases it."

  @impl true
  def parameters_schema do
    [name: [type: :string, required: true]]
  end

  @impl true
  def execute(%{"name" => name}, context) do
    test_pid = Map.fetch!(context, :test_pid)
    send(test_pid, {:tool_entered, name, self()})

    receive do
      {:release, ^name} -> {:ok, %{name: name}}
    after
      5_000 -> {:error, "timed out waiting for release"}
    end
  end
end

defmodule Tackle.Test.Adapter do
  @moduledoc false

  @behaviour Tackle.Lib.LLM

  alias Tackle.Lib.Cancellation

  @impl true
  def adapter_id, do: "test"

  @impl true
  def models, do: ["echo", "child"]

  @impl true
  def model_info(_model) do
    %{context_window: 1_000, max_output_tokens: 100}
  end

  @impl true
  def generate(_schema, opts) do
    test_pid = Keyword.get(opts, :test_pid, self())
    content = Keyword.get(opts, :content, "answer")
    signal = Keyword.get(opts, :cancellation_signal)

    send(test_pid, {:adapter_called, self(), Keyword.fetch!(opts, :model), opts})

    respond(Keyword.get(opts, :mode, :immediate), test_pid, content, signal, opts)
  end

  defp respond(:immediate, _test_pid, content, _signal, opts), do: response(content, opts)

  defp respond(:manual, test_pid, content, signal, opts),
    do: await_manual(test_pid, content, signal, opts)

  defp respond(:tool_then_answer, _test_pid, content, _signal, opts),
    do: tool_answer(content, opts, [Keyword.fetch!(opts, :tool_call)])

  defp respond(:tools_then_answer, _test_pid, content, _signal, opts),
    do: tool_answer(content, opts, Keyword.fetch!(opts, :tool_calls))

  defp respond(:echo_prompt, _test_pid, _content, _signal, opts),
    do: response(last_user_prompt(opts), opts)

  defp respond(:crash, _test_pid, _content, _signal, _opts), do: raise("adapter crash")

  defp respond(:error, _test_pid, _content, _signal, _opts), do: {:error, :adapter_error}

  defp respond(:block, _test_pid, _content, signal, _opts) do
    block_until_cancelled(signal)
    {:error, :cancelled}
  end

  defp tool_answer(content, opts, tool_calls) do
    if tool_result?(opts) do
      response(content, opts)
    else
      tool_calls_response(tool_calls, opts)
    end
  end

  defp await_manual(_test_pid, default_content, signal, opts) do
    receive do
      {:respond, content} -> response(content, opts)
      :crash -> raise "adapter crash"
      {:error, reason} -> {:error, reason}
    after
      5_000 ->
        if Cancellation.cancelled?(signal) do
          {:error, :cancelled}
        else
          response(default_content, opts)
        end
    end
  end

  defp block_until_cancelled(signal) do
    if Cancellation.cancelled?(signal) do
      :ok
    else
      Process.sleep(10)
      block_until_cancelled(signal)
    end
  end

  defp last_user_prompt(opts) do
    opts
    |> Keyword.get(:messages, [])
    |> Enum.filter(fn message -> Map.get(message, :role) == :user end)
    |> Enum.reverse()
    |> case do
      [_instruction, previous | _rest] -> Map.get(previous, :content, "")
      [only] -> Map.get(only, :content, "")
      [] -> ""
    end
  end

  defp tool_result?(opts) do
    opts
    |> Keyword.get(:messages, [])
    |> Enum.any?(fn
      %{role: :tool} -> true
      %{"role" => "tool"} -> true
      _other -> false
    end)
  end

  defp tool_calls_response(calls, opts) do
    {:ok,
     %{
       data: %{"content" => nil, "tool_calls" => calls},
       usage: nil,
       model: Keyword.fetch!(opts, :model),
       provider: adapter_id()
     }}
  end

  defp response(content, opts) do
    {:ok,
     %{
       data: %{"content" => content, "tool_calls" => []},
       usage: nil,
       model: Keyword.fetch!(opts, :model),
       provider: adapter_id()
     }}
  end
end

defmodule Tackle.Test.Runtime do
  @moduledoc false

  alias Tackle.Config
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.Handle
  alias Tackle.Runtime.Limits
  alias Tackle.Runtime.ScopeSpec
  alias Tackle.Session.Spec, as: SessionSpec

  @doc "Builds a trusted agent spec using the deterministic test adapter."
  def agent_spec(name, opts \\ []) do
    AgentSpec.new!(
      name: name,
      config: config(opts),
      allow_delegation: Keyword.get(opts, :allow_delegation, false),
      timeout: Keyword.get(opts, :timeout, 5_000)
    )
  end

  @doc "Builds a validated harness config for tests."
  def config(opts \\ []) do
    default_llm_opts = [
      test_pid: self(),
      mode: Keyword.get(opts, :mode, :immediate),
      content: Keyword.get(opts, :content, "answer")
    ]

    {:ok, config} =
      Config.new(
        adapters: [Tackle.Test.Adapter],
        model: Keyword.get(opts, :model, "test/echo"),
        tools: Keyword.get(opts, :tools, []),
        context: Keyword.get(opts, :context, %{}),
        system_prompt: Keyword.get(opts, :system_prompt, "You are a test agent."),
        max_iterations: Keyword.get(opts, :max_iterations, 5),
        llm_opts: Keyword.merge(default_llm_opts, Keyword.get(opts, :llm_opts, [])),
        compaction: Keyword.get(opts, :compaction)
      )

    config
  end

  @doc "Builds a scope spec with an allowlisted profile map."
  def scope_spec(opts \\ []) do
    root_opts = Keyword.get(opts, :root, [])
    limits = Keyword.get(opts, :limits, Limits.default())

    ScopeSpec.new!(
      root_spec: agent_spec("root", root_opts),
      limits: limits,
      profiles: Keyword.get(opts, :profiles, %{}),
      session: Keyword.get(opts, :session)
    )
  end

  @doc "Creates an isolated storage home removed when the test exits."
  def tmp_home do
    home =
      Path.join(
        System.tmp_dir!(),
        "tackle-session-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(home)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(home) end)
    home
  end

  @doc "Builds a validated durable session request rooted at an isolated home."
  def session_spec(opts \\ []) do
    home = Keyword.get_lazy(opts, :home, &tmp_home/0)
    opts = opts |> Keyword.delete(:home) |> Keyword.put(:storage, home: home)
    SessionSpec.new!(opts)
  end

  @doc "Starts a durable root scope rooted at an isolated storage home."
  def start_durable_scope(opts \\ []) do
    session_opts = Keyword.get(opts, :session, [])

    session_opts =
      case Keyword.fetch(opts, :home) do
        {:ok, home} -> Keyword.put_new(session_opts, :home, home)
        :error -> session_opts
      end

    session = session_spec(session_opts)
    start_scope(Keyword.put(opts, :session, session))
  end

  @doc "Starts a scope and registers cleanup for the current test."
  def start_scope(opts \\ []) do
    {:ok, scope} = Tackle.Runtime.start_scope(scope_spec(opts))
    ExUnit.Callbacks.on_exit(fn -> stop_scope(scope.scope_ref) end)
    scope
  end

  @doc "Stops a scope if it is still alive."
  def stop_scope(scope_ref) do
    Tackle.Runtime.stop_scope(scope_ref)
  catch
    :exit, _reason -> :ok
  end

  @doc "Builds an authorized runtime handle for a started scope."
  def handle(scope, opts \\ []) do
    Handle.new(scope.scope_ref, scope.root_agent_ref,
      allow_delegation: Keyword.get(opts, :allow_delegation, true),
      limits: Keyword.get(opts, :limits)
    )
  end

  @doc "Waits until `fun` returns a truthy value."
  def eventually(fun, attempts \\ 200)

  def eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end

  def eventually(_fun, 0), do: :timeout
end
