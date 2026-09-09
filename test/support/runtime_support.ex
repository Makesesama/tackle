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
    mode = Keyword.get(opts, :mode, :immediate)
    content = Keyword.get(opts, :content, "answer")
    signal = Keyword.get(opts, :cancellation_signal)

    send(test_pid, {:adapter_called, self(), Keyword.fetch!(opts, :model), opts})

    case mode do
      :immediate ->
        response(content, opts)

      :manual ->
        await_manual(test_pid, content, signal, opts)

      :tool_then_answer ->
        if tool_result?(opts) do
          response(content, opts)
        else
          tool_call_response(Keyword.fetch!(opts, :tool_call), opts)
        end

      :echo_prompt ->
        response(last_user_prompt(opts), opts)

      :crash ->
        raise "adapter crash"

      :error ->
        {:error, :adapter_error}

      :block ->
        block_until_cancelled(signal)
        {:error, :cancelled}
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

  defp tool_call_response(call, opts) do
    {:ok,
     %{
       data: %{"content" => nil, "tool_calls" => [call]},
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
  alias Tackle.Runtime.Limits
  alias Tackle.Runtime.ScopeSpec

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
        system_prompt: Keyword.get(opts, :system_prompt, "You are a test agent."),
        max_iterations: Keyword.get(opts, :max_iterations, 5),
        llm_opts: Keyword.merge(default_llm_opts, Keyword.get(opts, :llm_opts, []))
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
      profiles: Keyword.get(opts, :profiles, %{})
    )
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
    Tackle.Runtime.Handle.new(scope.scope_ref, scope.root_agent_ref,
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
