defmodule Tackle.CLI.Run do
  @moduledoc false

  @terminal_timeout 60_000

  @spec run(%{model: String.t() | nil, prompt: String.t() | nil}) :: non_neg_integer()
  def run(%{model: model, prompt: nil}) do
    case Tackle.CLI.TUI.start(model: model) do
      :ok -> 0
      {:error, reason} -> error(reason)
    end
  end

  def run(%{model: model, prompt: prompt}) when is_binary(prompt) do
    with {:ok, _apps} <- Application.ensure_all_started(:tackle),
         {:ok, session} <- Tackle.start_configured_session(overrides: overrides(model)) do
      run_prompt(session, prompt)
    else
      {:error, reason} -> error(reason)
      reason -> error(reason)
    end
  end

  @spec models() :: non_neg_integer()
  def models do
    with {:ok, _apps} <- Application.ensure_all_started(:tackle),
         {:ok, models} <- Tackle.available_models() do
      Enum.each(models, &IO.puts/1)
      0
    else
      {:error, reason} -> error(reason)
      reason -> error(reason)
    end
  end

  defp run_prompt(session, prompt) do
    with {:ok, snapshot} <- Tackle.subscribe(session),
         {:ok, turn_id} <- Tackle.submit(session, prompt),
         {:ok, answer} <- await_answer(snapshot.session_id, turn_id) do
      Tackle.close(session)
      IO.puts(answer)
      0
    else
      {:error, reason} ->
        Tackle.close(session)
        error(reason)
    end
  end

  defp await_answer(session_id, turn_id) do
    receive do
      {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, agent_state}} ->
        {:ok, Tackle.Lib.last_answer(agent_state) || ""}

      {:tackle_turn_finished, ^session_id, ^turn_id, {:cancelled, _agent_state}} ->
        {:error, :cancelled}

      {:tackle_turn_finished, ^session_id, ^turn_id, {:error, _agent_state}} ->
        {:error, :turn_failed}

      {:tackle_turn_failed, ^session_id, ^turn_id, reason} ->
        {:error, reason}

      {:tackle_event, ^session_id, ^turn_id, _event} ->
        await_answer(session_id, turn_id)
    after
      @terminal_timeout -> {:error, :timeout}
    end
  end

  defp overrides(nil), do: []
  defp overrides(model), do: [model: model]

  defp error(reason) do
    IO.puts(:stderr, "error: #{inspect(reason)}")
    1
  end
end
