defmodule Tackle.Review.Delegation do
  @moduledoc """
  Starts and awaits the delegated runs of the review stages.

  Each run uses a trusted profile spec (normally from the scope's profiles)
  with the stage's per-run data placed under `:review` in the session
  context, where the stage's output tool reads it. The run is requested from
  the review's requester through `Tackle.Runtime.request_agent/4`, so it is
  admitted, limited, and cancelled like any other delegated run and shows up
  among the scope's tasks.

  The calling process owns the run: if it exits, the runtime cancels the run.
  The runtime refuses rather than queues work at capacity, so a capacity
  refusal is retried until `:capacity_wait` passes.

  A run that ends with an error after doing useful work (for example on the
  step limit, or when the model call after its report fails) still returns
  its final state, so a stage can keep what the run reported.
  """

  alias Tackle.Config
  alias Tackle.Lib.{State, Usage}
  alias Tackle.Runtime
  alias Tackle.Runtime.{AgentRef, AgentSpec, Handle, Outcome, RootBackend}

  # Transient capacity refusals of `Tackle.AgentScope.Coordinator`.
  @capacity_reasons [:max_children_per_agent, :max_agents_per_fleet]
  @capacity_poll_ms 20
  @default_capacity_wait :timer.seconds(60)

  @typedoc "The agent the review's runs are delegated from."
  @type requester :: Handle.t() | AgentRef.t()

  @typedoc """
  Why a run produced no usable result:

    * `:cancelled` - the run, its parent, or the scope was cancelled;
    * `{:agent_error, message}` - the agent loop ended with an error;
    * `:timeout` - the run was inactive for too long;
    * `{:runtime_error, reason}` - the run crashed;
    * `{:rejected, reason}` - the runtime refused to start it;
    * `{:request_failed, reason}` - the request could not be made, for
      example for an unavailable model;
    * `{:unavailable, reason}` - the run's outcome could not be collected.
  """
  @type error ::
          :cancelled
          | {:agent_error, String.t()}
          | :timeout
          | {:runtime_error, term()}
          | {:rejected, term()}
          | {:request_failed, term()}
          | {:unavailable, term()}

  @typedoc """
  Run options:

    * `:model` - a `"provider/model"` reference overriding the profile's model;
    * `:capacity_wait` - how long to retry capacity refusals, in milliseconds
      (default 60 seconds).
  """
  @type option :: {:model, String.t() | nil} | {:capacity_wait, non_neg_integer()}

  @doc """
  Returns `spec` with `review` stored under `:review` in its session context.

  Only harness configurations (`Tackle.Config`) are supported.
  """
  @spec put_review_context(AgentSpec.t(), map()) ::
          {:ok, AgentSpec.t()} | {:error, {:unsupported_agent_config, String.t()}}
  def put_review_context(%AgentSpec{config: %Config{} = config} = spec, review)
      when is_map(review) do
    {:ok, %{spec | config: %{config | context: Map.put(config.context, :review, review)}}}
  end

  def put_review_context(%AgentSpec{name: name}, _review),
    do: {:error, {:unsupported_agent_config, name}}

  @doc """
  Returns the configuration a run of `spec` requested from `requester`
  starts with, before any `:model` override, without starting a run.

  A profile that inherits its model (`model_source: :parent`) runs on the
  requester's current model and thinking level, as `Tackle.Runtime` applies
  them when a run starts; any other profile keeps its own configuration.
  """
  @spec base_config(requester(), AgentSpec.t()) ::
          {:ok, Config.t()}
          | {:error,
             {:requester_model_unavailable, term()} | {:unsupported_agent_config, String.t()}}
  def base_config(requester, %AgentSpec{config: %Config{} = config, model_source: :parent}) do
    with {:ok, %{agent_state: %State{} = state}} <-
           Runtime.session_snapshot(agent_ref(requester)),
         {:ok, config} <- RootBackend.inherit_model(config, state) do
      {:ok, config}
    else
      {:error, reason} -> {:error, {:requester_model_unavailable, reason}}
      other -> {:error, {:requester_model_unavailable, other}}
    end
  end

  def base_config(_requester, %AgentSpec{config: %Config{} = config}), do: {:ok, config}

  def base_config(_requester, %AgentSpec{name: name}),
    do: {:error, {:unsupported_agent_config, name}}

  @doc """
  Runs one delegated agent to completion and returns its final state.

  Blocks until the run settles. A run that settles normally returns
  `{:ok, state}`. A run whose agent loop ended with an error returns
  `{:error, {:agent_error, message}, state}` with its final state, whose
  transcript may still hold what the run reported before the error. Every
  other failure returns `{:error, reason}`; see `t:error/0`.
  """
  @spec run(requester(), AgentSpec.t(), String.t(), [option()]) ::
          {:ok, State.t()}
          | {:error, {:agent_error, String.t()}, State.t()}
          | {:error, error()}
  def run(requester, %AgentSpec{} = spec, prompt, opts \\ []) when is_binary(prompt) do
    request_opts = if model = Keyword.get(opts, :model), do: [model: model], else: []
    wait = Keyword.get(opts, :capacity_wait, @default_capacity_wait)
    deadline = System.monotonic_time(:millisecond) + wait

    with {:ok, run_ref} <- request(requester, spec, prompt, request_opts, deadline) do
      run_ref |> Runtime.await(:infinity) |> settle()
    end
  end

  @doc "Sums the token usage of a run's assistant messages."
  @spec usage(State.t()) :: Usage.t()
  def usage(%State{messages: messages}) do
    messages
    |> Enum.filter(&(&1.role == :assistant))
    |> Enum.map(& &1.token_usage)
    |> Usage.aggregate()
  end

  @doc "Describes a run error for people."
  @spec format_error(error()) :: String.t()
  def format_error(:cancelled), do: "cancelled"
  def format_error(:timeout), do: "timed out"
  def format_error({:agent_error, message}), do: "agent failed: #{message}"
  def format_error({:runtime_error, reason}), do: "agent crashed: #{inspect(reason)}"
  def format_error({:rejected, reason}), do: "run refused: #{inspect(reason)}"
  def format_error({:request_failed, reason}), do: "could not start the run: #{inspect(reason)}"
  def format_error({:unavailable, reason}), do: "result unavailable: #{inspect(reason)}"
  def format_error(other), do: inspect(other)

  defp request(requester, spec, prompt, opts, deadline) do
    case Runtime.request_agent(requester, spec, prompt, opts) do
      {:ok, run_ref} ->
        {:ok, run_ref}

      {:error, {:rejected, reason}} when reason in @capacity_reasons ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@capacity_poll_ms)
          request(requester, spec, prompt, opts, deadline)
        else
          {:error, {:rejected, reason}}
        end

      {:error, {:rejected, reason}} ->
        if cancelled_refusal?(reason),
          do: {:error, :cancelled},
          else: {:error, {:rejected, reason}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp agent_ref(%Handle{agent_ref: agent_ref}), do: agent_ref
  defp agent_ref(%AgentRef{} = agent_ref), do: agent_ref

  defp cancelled_refusal?(:cancelled), do: true
  defp cancelled_refusal?({:scope_cancelled, _reason}), do: true
  defp cancelled_refusal?(_reason), do: false

  defp settle(%Outcome{status: :ok, agent_state: %State{} = state}), do: {:ok, state}
  defp settle(%Outcome{status: :cancelled}), do: {:error, :cancelled}
  defp settle(%Outcome{status: :timeout}), do: {:error, :timeout}

  defp settle(%Outcome{status: :error, agent_state: %State{} = state} = outcome),
    do: {:error, {:agent_error, Outcome.message(outcome)}, state}

  defp settle(%Outcome{status: :runtime_error, reason: reason}),
    do: {:error, {:runtime_error, reason}}

  defp settle(%Outcome{status: :rejected, reason: reason}), do: {:error, {:rejected, reason}}
  defp settle({:error, reason}), do: {:error, {:unavailable, reason}}
end
