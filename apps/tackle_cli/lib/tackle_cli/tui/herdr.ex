defmodule Tackle.CLI.TUI.Herdr do
  @moduledoc """
  Keeps a Herdr pane in sync with the interactive shell.

  Only the interactive shell reports. A one-shot `tackle run "prompt"`, the
  SDK server, and other headless commands stay silent, like Herdr's own Pi
  integration, which reports only in Pi's TUI mode: a headless run has no
  screen for Herdr to show and nothing to resume.

  The shell reports `working` while a turn or shell operation runs and `idle`
  otherwise; Tackle has no approval prompts, so it never reports `blocked`.
  Once the session is durable, the report also carries the session id and the
  command that resumes it (`Tackle.CLI.Herdr.resume_argv/1`). A new session is
  materialized on its first prompt, so a session without messages or an active
  turn reports no resume command; until it has one, Herdr keeps the previous
  session's command. Switching sessions with `/new` or `/resume` reports the
  new session, and quitting releases the pane.

  The shell starts the reporter when it mounts, keeps it and the last report
  it sent in its state, and calls `refresh/1` from the same transitions that
  refresh the terminal title. Reports are only sent when they change; the
  socket contract lives in `Tackle.CLI.Herdr`.
  """

  alias Tackle.CLI.Herdr.Reporter
  alias Tackle.CLI.TUI.State
  alias Tackle.Lib.State, as: AgentState

  @typedoc "The shell's reporter and the last report it was asked to send."
  @type t :: %__MODULE__{reporter: pid(), reported: Tackle.CLI.Herdr.report() | nil}

  @enforce_keys [:reporter]
  defstruct [:reporter, reported: nil]

  @doc """
  Starts reporting for a shell mounted with `opts`, or returns `nil`.

  `:herdr_reporter` injects a running reporter. Test shells never read the
  real environment; otherwise a reporter starts only inside a Herdr pane.
  """
  @spec start(keyword()) :: t() | nil
  def start(opts) do
    cond do
      Keyword.has_key?(opts, :herdr_reporter) ->
        new(Keyword.fetch!(opts, :herdr_reporter))

      Keyword.has_key?(opts, :test_mode) ->
        nil

      true ->
        start_from_env()
    end
  end

  defp start_from_env do
    with {:ok, config} <- Tackle.CLI.Herdr.config(),
         {:ok, reporter} <- Reporter.start_link(config) do
      new(reporter)
    else
      _disabled_or_failed -> nil
    end
  end

  defp new(reporter) when is_pid(reporter), do: %__MODULE__{reporter: reporter}
  defp new(nil), do: nil

  @doc "Returns the report that describes `state`, given the previous report."
  @spec report(State.t(), Tackle.CLI.Herdr.report() | nil) :: Tackle.CLI.Herdr.report()
  def report(%State{} = state, previous) do
    session_id = if resumable?(state, previous), do: state.session_id

    %{
      state: activity(state),
      session_id: session_id,
      resume_argv: session_id && Tackle.CLI.Herdr.resume_argv(session_id)
    }
  end

  @doc "Sends the report for `state` when it changed since the last one."
  @spec refresh(State.t()) :: State.t()
  def refresh(%State{herdr: nil} = state), do: state

  def refresh(%State{herdr: %__MODULE__{} = herdr} = state) do
    report = report(state, herdr.reported)

    if report == herdr.reported do
      state
    else
      :ok = Reporter.report(herdr.reporter, report)
      %{state | herdr: %{herdr | reported: report}}
    end
  end

  @doc "Releases the pane when the shell exits; a no-op outside Herdr."
  @spec release(State.t()) :: :ok
  def release(%State{herdr: nil}), do: :ok
  def release(%State{herdr: %__MODULE__{reporter: reporter}}), do: Reporter.release(reporter)

  defp activity(%State{active_turn: nil, pending_operation: nil}), do: :idle
  defp activity(%State{}), do: :working

  defp resumable?(%State{session_id: nil}, _previous), do: false

  # Once a session has been reported as resumable it stays resumable.
  defp resumable?(%State{session_id: id}, %{session_id: id}), do: true
  defp resumable?(%State{active_turn: turn}, _previous) when not is_nil(turn), do: true
  defp resumable?(%State{agent_state: %AgentState{messages: [_ | _]}}, _previous), do: true
  defp resumable?(%State{}, _previous), do: false
end
