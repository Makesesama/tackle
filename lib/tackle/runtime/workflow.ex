defmodule Tackle.Runtime.Workflow do
  @moduledoc """
  Behaviour for host-defined workflows.

  A workflow is a deterministic coordinator for agents and runs, not an agent
  and not a second loop implementation. The host module owns workflow state,
  accumulated results, and failure policy; `Tackle.Runtime.Workflow.Server`
  provides the process, correlated result routing, cancellation, and lifecycle.

  Workflows declare requests declaratively. Each request names an allowlisted
  profile and a prompt; the server launches it through the same
  `Tackle.Runtime.request_agent/4` primitive the subagent tool uses, so scope
  limits, depth, and cancellation apply unchanged.

  ## Callbacks

    * `init/1` — receives the workflow input, returns initial state and optional
      first requests.
    * `handle_result/3` — receives one successful run outcome and its `RunRef`.
    * `handle_failure/3` — receives any non-`ok` outcome. Defaults to stopping
      with `{:error, {:child_failed, outcome}}`.
    * `handle_cancelled/2` — receives the cancellation reason. Defaults to
      stopping with `{:error, {:cancelled, reason}}`.

  Callbacks return `{:ok, state}`, `{:ok, state, requests}`, or
  `{:stop, result, state}`. The workflow process stops when a callback returns
  `{:stop, ...}` and replies with `result` to `await_workflow/2` callers.
  """

  alias Tackle.Runtime.Outcome
  alias Tackle.Runtime.RunRef

  @type request ::
          {profile :: String.t(), prompt :: String.t()}
          | {String.t(), String.t(), keyword()}
          | %{
              required(:profile) => String.t(),
              required(:prompt) => String.t(),
              optional(:opts) => keyword()
            }

  @callback init(input :: term()) ::
              {:ok, state :: term()}
              | {:ok, state :: term(), [request()]}
              | {:stop, reason :: term()}

  @callback handle_result(run_ref :: RunRef.t(), outcome :: Outcome.t(), state :: term()) ::
              {:ok, state :: term()}
              | {:ok, state :: term(), [request()]}
              | {:stop, result :: term(), state :: term()}

  @callback handle_failure(run_ref :: RunRef.t(), outcome :: Outcome.t(), state :: term()) ::
              {:ok, state :: term()}
              | {:ok, state :: term(), [request()]}
              | {:stop, result :: term(), state :: term()}

  @callback handle_cancelled(reason :: term(), state :: term()) ::
              {:stop, result :: term(), state :: term()}

  @optional_callbacks handle_failure: 3, handle_cancelled: 2

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour Tackle.Runtime.Workflow

      @impl Tackle.Runtime.Workflow
      def handle_failure(_run_ref, outcome, state) do
        {:stop, {:error, {:child_failed, outcome}}, state}
      end

      @impl Tackle.Runtime.Workflow
      def handle_cancelled(reason, state) do
        {:stop, {:error, {:cancelled, reason}}, state}
      end

      defoverridable handle_failure: 3, handle_cancelled: 2
    end
  end

  @doc false
  @spec normalize_request(request()) :: {String.t(), String.t(), keyword()}
  def normalize_request({profile, prompt}) when is_binary(profile) and is_binary(prompt),
    do: {profile, prompt, []}

  def normalize_request({profile, prompt, opts})
      when is_binary(profile) and is_binary(prompt) and is_list(opts),
      do: {profile, prompt, opts}

  def normalize_request(%{profile: profile, prompt: prompt} = request)
      when is_binary(profile) and is_binary(prompt),
      do: {profile, prompt, Map.get(request, :opts, [])}

  def normalize_request(other) do
    raise ArgumentError, "invalid workflow request: #{inspect(other)}"
  end
end
