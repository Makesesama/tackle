defmodule Tackle.Lib.Compaction.Plan do
  @moduledoc """
  Balanced cut selection for one compaction pass.

  A plan splits the provider-visible model message projection into an old
  `shadowed` prefix that is replaced by a synthetic checkpoint and a `retained`
  verbatim tail. Selection is structural, not a raw index slice:

    * it never begins the retained tail with an orphan tool result;
    * it never separates an assistant tool call from its linked results;
    * it prefers a user-turn boundary when one exists; and
    * it keeps at least the retention budget of recent messages where possible.

  All decisions are deterministic and derived from stable message ids so the
  same projection and policy always produce the same plan.
  """

  alias Tackle.Lib.ContextUsage
  alias Tackle.Lib.Message

  @type t :: %__MODULE__{
          cut_index: non_neg_integer(),
          shadowed: [Message.t()],
          retained: [Message.t()],
          shadowed_ids: [String.t()],
          first_retained_id: String.t() | nil,
          tokens_before: non_neg_integer(),
          shadowed_tokens: non_neg_integer(),
          retained_tokens: non_neg_integer()
        }

  @enforce_keys [:cut_index, :shadowed, :retained]
  defstruct cut_index: 0,
            shadowed: [],
            retained: [],
            shadowed_ids: [],
            first_retained_id: nil,
            tokens_before: 0,
            shadowed_tokens: 0,
            retained_tokens: 0

  @doc """
  Selects a compaction plan for `messages`.

  `:retain_tokens` sets the minimum token budget kept verbatim in the tail.
  Returns `{:error, :nothing_to_shadow}` when no structurally valid cut exists.
  """
  @spec select([Message.t()], keyword()) :: {:ok, t()} | {:error, term()}
  def select(messages, opts \\ []) when is_list(messages) do
    retain_tokens = Keyword.get(opts, :retain_tokens, 0)

    with {:ok, candidates} <- candidates(messages),
         {:ok, cut} <- choose_cut(messages, candidates, retain_tokens) do
      {:ok, build(messages, cut)}
    end
  end

  defp candidates(messages) do
    last = length(messages) - 1

    candidates =
      if last < 1 do
        []
      else
        1..last
        |> Enum.filter(&valid_boundary?(messages, &1))
      end

    case candidates do
      [] -> {:error, :nothing_to_shadow}
      candidates -> {:ok, candidates}
    end
  end

  defp valid_boundary?(messages, index) do
    message = Enum.at(messages, index)
    previous = Enum.at(messages, index - 1)

    message.role in [:user, :assistant] and not Message.has_tool_calls?(previous)
  end

  defp choose_cut(messages, candidates, retain_tokens) do
    satisfying =
      Enum.filter(candidates, fn index -> tail_tokens(messages, index) >= retain_tokens end)

    cut =
      case satisfying do
        [] -> List.first(candidates)
        list -> List.last(list)
      end

    cut = prefer_user_boundary(messages, candidates, cut)

    if cut > 0 and cut < length(messages) do
      {:ok, cut}
    else
      {:error, :nothing_to_shadow}
    end
  end

  # Retaining a little more to begin the tail at a user turn is preferred over a
  # mid-turn assistant boundary. User boundaries are always structurally valid;
  # when none exist (for example, one oversized turn) the budget cut stands.
  defp prefer_user_boundary(messages, candidates, cut) do
    user_candidates =
      Enum.filter(candidates, fn index -> Enum.at(messages, index).role == :user end)

    case Enum.filter(user_candidates, &(&1 <= cut)) do
      [] -> cut
      list -> List.last(list)
    end
  end

  defp build(messages, cut) do
    shadowed = Enum.take(messages, cut)
    retained = Enum.drop(messages, cut)

    %__MODULE__{
      cut_index: cut,
      shadowed: shadowed,
      retained: retained,
      shadowed_ids: Enum.map(shadowed, & &1.id),
      first_retained_id:
        case retained do
          [%Message{id: id} | _rest] -> id
          [] -> nil
        end,
      tokens_before: ContextUsage.estimate_messages(messages),
      shadowed_tokens: ContextUsage.estimate_messages(shadowed),
      retained_tokens: ContextUsage.estimate_messages(retained)
    }
  end

  defp tail_tokens(messages, index),
    do: messages |> Enum.drop(index) |> ContextUsage.estimate_messages()
end
