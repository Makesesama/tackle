defmodule Tackle do
  @moduledoc """
  Public facade for the frontend-independent Tackle developer harness.

  A session is configured with already-loaded adapter and capability modules,
  supervised by the Tackle application, and addressed by its session process.
  """

  alias Tackle.Config
  alias Tackle.Session

  @doc """
  Starts a supervised in-memory session from validated configuration or options.

  Options require `:adapters` and a canonical `:model` reference such as
  `"openai-codex/gpt-5.5"`. See `Tackle.Config.new/1`.
  """
  @spec start_session(Config.t() | keyword()) ::
          DynamicSupervisor.on_start_child() | {:error, term()}
  def start_session(%Config{} = config), do: Session.start_child(config)

  def start_session(opts) when is_list(opts) do
    with {:ok, config} <- Config.new(opts) do
      start_session(config)
    end
  end

  def start_session(opts), do: {:error, {:invalid_config, opts}}

  @doc "Starts a turn and appends one user message."
  defdelegate submit(session, input), to: Session

  @doc "Continues the conversation without appending another user message."
  defdelegate continue(session), to: Session

  @doc "Requests cooperative cancellation of the active turn."
  defdelegate cancel(session), to: Session

  @doc "Returns an atomic session snapshot."
  defdelegate snapshot(session), to: Session

  @doc "Subscribes the caller to correlated session events and terminal outcomes."
  defdelegate subscribe(session), to: Session

  @doc "Unsubscribes the caller from session deliveries."
  defdelegate unsubscribe(session), to: Session

  @doc "Closes a session and cleans up its active turn."
  defdelegate close(session), to: Session
end
