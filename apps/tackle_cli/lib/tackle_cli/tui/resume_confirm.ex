defmodule Tackle.CLI.TUI.ResumeConfirm do
  @moduledoc """
  Asks before reopening a session whose provider prompt cache has expired.

  Providers cache the prompt prefix for minutes, at most about an hour
  (Anthropic's default is five minutes; OpenAI keeps an idle prefix for five to
  ten minutes and evicts it within an hour). The first request after resuming
  an older session therefore re-sends its whole context uncached, which can be
  expensive for a long session. Before that happens the shell shows the
  session's age and estimated context size, plus an input-cost estimate when
  the session's model is the current one and declares a price card.

  Sessions updated within `stale_after/0`, and sessions whose known context is
  below `negligible_tokens/0`, resume without asking. A catalog summary written
  before context estimates existed has no `:context_tokens`; the prompt then
  opens immediately and the estimate is filled in through the frontend's
  session inspector.

  Confirming also restores an archived session before resuming it.
  """

  alias ExRatatui.Command
  alias Tackle.CLI.TUI.{MessageView, RecentSessions, Session, State, Util}
  alias Tackle.Lib.ModelInfo

  @stale_after_seconds 3600
  @negligible_tokens 10_000

  @typedoc "The overlay value while the prompt is open."
  @type t :: %{
          session: map(),
          context_tokens: non_neg_integer() | nil | :loading,
          estimate_ref: reference() | nil,
          return: State.overlay()
        }

  @doc "Seconds after the last update when a session's prompt cache counts as expired."
  @spec stale_after() :: pos_integer()
  def stale_after, do: @stale_after_seconds

  @doc "Context size below which reopening a stale session is cheap enough not to ask."
  @spec negligible_tokens() :: pos_integer()
  def negligible_tokens, do: @negligible_tokens

  @doc """
  Whether resuming `session` should ask first.

  `session` is a catalog summary map. A session without a parseable
  `:updated_at` is treated as stale, since its age is unknown.
  """
  @spec confirm?(map(), DateTime.t()) :: boolean()
  def confirm?(session, now \\ DateTime.utc_now()) do
    stale?(session, now) and not negligible?(Map.get(session, :context_tokens))
  end

  defp stale?(session, now) do
    case updated_at(session) do
      {:ok, at} -> DateTime.diff(now, at) >= @stale_after_seconds
      :error -> true
    end
  end

  defp negligible?(tokens) when is_integer(tokens), do: tokens < @negligible_tokens
  defp negligible?(_unknown), do: false

  @doc """
  Resumes `session`, asking first when its prompt cache has likely expired.

  The open overlay (the `/resume` picker, for example) is kept and restored
  when the prompt is cancelled. Callers gate availability (idle shell).
  """
  @spec request(State.t(), map()) :: {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def request(%State{} = state, session) do
    if confirm?(session) do
      open(state, session)
    else
      perform(state, session)
    end
  end

  defp open(state, session) do
    confirm = %{
      session: session,
      context_tokens: Map.get(session, :context_tokens),
      estimate_ref: nil,
      return: state.overlay
    }

    case {confirm.context_tokens, state.inspect_session} do
      {nil, inspector} when is_function(inspector, 1) ->
        ref = make_ref()
        session_id = session.session_id

        command =
          Command.async(
            fn -> inspector.(session_id) end,
            &{:tui_resume_estimate_result, ref, session_id, &1}
          )

        confirm = %{confirm | context_tokens: :loading, estimate_ref: ref}
        {:noreply, %{state | overlay: {:confirm_resume, confirm}}, commands: [command]}

      _known_or_unavailable ->
        {:noreply, %{state | overlay: {:confirm_resume, confirm}}}
    end
  end

  @doc "Handles a resolved yes/no intent while the prompt is open."
  @spec handle(:confirm | :cancel | :ignore, State.t()) ::
          {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def handle(:confirm, %State{overlay: {:confirm_resume, confirm}} = state),
    do: perform(state, confirm.session)

  def handle(:cancel, %State{overlay: {:confirm_resume, confirm}} = state),
    do: {:noreply, %{state | overlay: confirm.return}}

  def handle(_intent, %State{} = state), do: {:noreply, state, render?: false}

  @doc "Installs the context estimate loaded for an open prompt."
  @spec apply_estimate(State.t(), reference(), String.t(), term()) ::
          {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def apply_estimate(
        %State{overlay: {:confirm_resume, %{estimate_ref: ref} = confirm}} = state,
        ref,
        _session_id,
        result
      ) do
    tokens =
      case result do
        {:ok, %{metadata: %{context_tokens: tokens}}} when is_integer(tokens) -> tokens
        _unavailable -> nil
      end

    confirm = %{confirm | context_tokens: tokens, estimate_ref: nil}
    {:noreply, %{state | overlay: {:confirm_resume, confirm}}}
  end

  def apply_estimate(%State{} = state, _ref, _session_id, _result),
    do: {:noreply, state, render?: false}

  # An archived session is restored first; a failed restore leaves everything
  # as it was and reports why.
  defp perform(state, %{archived: true} = session) do
    case unarchive(state, session.session_id) do
      :ok ->
        {state, commands} = RecentSessions.load(state)
        state |> Session.resume_by_id(session.session_id) |> with_commands(commands)

      {:error, reason} ->
        {:noreply, %{state | overlay: nil, error: Util.format_reason(reason)}}
    end
  end

  defp perform(state, session), do: Session.resume_by_id(state, session.session_id)

  defp unarchive(%State{unarchive_session: nil}, _session_id),
    do: {:error, "Restoring archived sessions is unavailable in this frontend"}

  defp unarchive(%State{unarchive_session: unarchive}, session_id) do
    case unarchive.(session_id) do
      :ok -> :ok
      {:error, reason} -> {:error, {:unarchive_failed, reason}}
      other -> {:error, {:unarchive_failed, other}}
    end
  rescue
    error -> {:error, {:unarchive_failed, error}}
  catch
    :exit, reason -> {:error, {:unarchive_failed, {:exit, reason}}}
  end

  defp with_commands({:noreply, state}, []), do: {:noreply, state}
  defp with_commands({:noreply, state}, commands), do: {:noreply, state, commands: commands}

  defp with_commands({:noreply, state, opts}, commands),
    do: {:noreply, state, Keyword.update(opts, :commands, commands, &(commands ++ &1))}

  # -- presentation ------------------------------------------------------------

  @doc "Returns the prompt body for the open overlay."
  @spec text(State.t()) :: String.t()
  def text(%State{overlay: {:confirm_resume, confirm}} = state) do
    session = confirm.session

    action =
      if Map.get(session, :archived) == true,
        do: "Restore and resume",
        else: "Resume"

    [
      " #{action} \"#{title(session)}\"?",
      "",
      " " <> facts(session, confirm.context_tokens),
      "",
      " The provider's prompt cache has likely expired, so the first",
      " request re-sends the whole context without cache discounts." <>
        cost_suffix(state, session, confirm.context_tokens)
    ]
    |> Enum.join("\n")
  end

  defp title(session) do
    (Map.get(session, :title) || Map.get(session, :preview) || session.session_id)
    |> MessageView.sanitize()
    |> String.split("\n", parts: 2)
    |> hd()
    |> Util.truncate(48)
  end

  defp facts(session, tokens) do
    [age(session), messages(session), context(tokens)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp age(session) do
    case updated_at(session) do
      {:ok, at} -> "last active " <> relative(DateTime.diff(DateTime.utc_now(), at))
      :error -> "last activity unknown"
    end
  end

  defp relative(seconds) when seconds < 0, do: relative(0)
  defp relative(seconds) when seconds < 7200, do: "#{div(seconds, 60)}m ago"
  defp relative(seconds) when seconds < 172_800, do: "#{div(seconds, 3600)}h ago"
  defp relative(seconds), do: "#{div(seconds, 86_400)}d ago"

  defp messages(session) do
    case Map.get(session, :message_count) do
      1 -> "1 message"
      count when is_integer(count) -> "#{count} messages"
      _unknown -> nil
    end
  end

  defp context(:loading), do: "estimating context…"
  defp context(tokens) when is_integer(tokens), do: "≈ #{format_tokens(tokens)} tokens of context"
  defp context(_unknown), do: "context size unknown"

  # Only the current model's price card is known here, so a session recorded
  # with another model gets no price.
  defp cost_suffix(%State{agent_state: agent_state}, session, tokens) when is_integer(tokens) do
    with model when is_binary(model) <- Map.get(session, :model),
         true <- agent_state != nil and model == State.model_ref(agent_state),
         %ModelInfo{pricing: %{} = pricing} <- State.model_info(agent_state),
         amount when is_number(amount) <- input_cost(tokens, pricing) do
      "\n Uncached input: ≈ " <> format_cost(amount, pricing.currency) <> "."
    else
      _unpriced -> ""
    end
  end

  defp cost_suffix(_state, _session, _tokens), do: ""

  defp input_cost(tokens, %{input: input, unit_tokens: unit})
       when is_number(input) and is_integer(unit) and unit > 0,
       do: tokens * input / unit

  defp input_cost(_tokens, _pricing), do: nil

  defp format_cost(amount, currency) do
    decimals = if amount < 0.01, do: 4, else: 2
    value = :erlang.float_to_binary(amount / 1, decimals: decimals)
    if currency == "USD", do: "$" <> value, else: "#{currency} #{value}"
  end

  defp format_tokens(tokens) when tokens < 1_000, do: Integer.to_string(tokens)
  defp format_tokens(tokens) when tokens < 1_000_000, do: "#{round(tokens / 1_000)}k"

  defp format_tokens(tokens),
    do: :erlang.float_to_binary(tokens / 1_000_000, decimals: 1) <> "M"

  defp updated_at(session) do
    case Map.get(session, :updated_at) || Map.get(session, :created_at) do
      iso when is_binary(iso) ->
        case DateTime.from_iso8601(iso) do
          {:ok, at, _offset} -> {:ok, at}
          {:error, _reason} -> :error
        end

      _missing ->
        :error
    end
  end
end
