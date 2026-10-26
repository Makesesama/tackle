defmodule Tackle.Lib.Compaction.Plan do
  @moduledoc """
  Balanced cut selection for one compaction pass.

  A plan splits the provider-visible model message projection into an old
  `shadowed` prefix that is replaced by a synthetic checkpoint and a `retained`
  verbatim tail. Selection is structural, not a raw index slice. A cut is only
  valid where no tool call is still waiting for its result, so:

    * the retained tail never begins with a tool result;
    * an assistant tool call is never separated from any of its results, even
      when other messages sit between them; and
    * a cut never shadows only an earlier checkpoint (`:checkpoint_id`),
      which would summarize a summary without shadowing anything new.

  The cut keeps approximately `:retain_tokens` verbatim: it is the first valid
  boundary at or after the message that crosses the target, counted from the
  end, so it naturally lands on a turn boundary and summarizes a long turn's
  prefix rather than keeping that entire turn.

  `:max_retained_tokens` caps the tail. When one oversized message (such as a
  huge tool result) would keep the tail above the cap, or no boundary keeps a
  tail at all (a checkpoint followed by a single turn, say), the cut moves on,
  up to shadowing every message, so a compaction never keeps verbatim what
  cannot fit after it. Retained messages are measured as they will be sent
  after compaction, without their provider continuation state.

  Selection returns `{:error, :nothing_to_shadow}` when no valid cut exists or
  when the whole projection already fits the retention target.

  All decisions are deterministic and derived from stable message ids so the
  same projection and policy always produce the same plan.
  """

  alias Tackle.Lib.ContextUsage
  alias Tackle.Lib.Message
  alias Tackle.Lib.Tool.Call

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

  ## Options

    * `:retain_tokens` - the approximate token target kept verbatim in the
      tail (default 0).
    * `:max_retained_tokens` - the most tokens the tail may keep, or `nil`
      (the default) for no cap.
    * `:checkpoint_id` - the id of the earlier checkpoint leading `messages`
      (the summary message of the branch's last compaction record), or `nil`
      (the default) when there is none. Only that message counts as a
      checkpoint; message content never does.

  Returns `{:error, :nothing_to_shadow}` when no structurally valid cut exists
  or the projection already fits `:retain_tokens`.
  """
  @spec select([Message.t()], keyword()) :: {:ok, t()} | {:error, :nothing_to_shadow}
  def select(messages, opts \\ []) when is_list(messages) do
    retain_tokens = Keyword.get(opts, :retain_tokens, 0)
    max_retained = Keyword.get(opts, :max_retained_tokens)
    sizes = Enum.map(messages, &retained_size/1)
    tails = tails(sizes)

    if elem(tails, 0) <= retain_tokens do
      {:error, :nothing_to_shadow}
    else
      cuts = valid_cuts(messages, Keyword.get(opts, :checkpoint_id))

      case choose_cut(cuts, sizes, tails, retain_tokens, max_retained) do
        nil -> {:error, :nothing_to_shadow}
        cut -> {:ok, build(messages, cut, elem(tails, cut))}
      end
    end
  end

  # `tails` holds, at index `i`, the retained size of `messages[i..]`, with a
  # final 0 for the empty tail.
  defp tails(sizes) do
    sizes
    |> Enum.reverse()
    |> Enum.scan(&(&1 + &2))
    |> Enum.reverse()
    |> Kernel.++([0])
    |> List.to_tuple()
  end

  defp choose_cut(cuts, sizes, tails, retain_tokens, max_retained) do
    count = length(sizes)
    candidates = Enum.filter(cuts, &(&1 < count))
    target_index = retention_target_index(sizes, retain_tokens)

    # The first valid boundary at or after the message that crossed the
    # target. This deliberately does not require the retained tail to meet a
    # minimum: one oversized tool result or response should be summarized,
    # not force the entire containing turn to remain verbatim.
    preferred = Enum.find(candidates, &(&1 >= target_index)) || List.last(candidates)

    cond do
      is_nil(max_retained) ->
        preferred

      not is_nil(preferred) and elem(tails, preferred) <= max_retained ->
        preferred

      # The tail must not keep what cannot fit, so the cut moves on, up to
      # shadowing everything.
      true ->
        Enum.find(cuts, &(elem(tails, &1) <= max_retained)) || List.last(cuts)
    end
  end

  defp retention_target_index(sizes, retain_tokens) do
    sizes
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.reduce_while({0, 0}, fn {size, index}, {tokens, _index} ->
      tokens = tokens + size

      if tokens >= retain_tokens do
        {:halt, {tokens, index}}
      else
        {:cont, {tokens, index}}
      end
    end)
    |> elem(1)
  end

  # Cut `i` (shadowing `messages[0..i-1]`) is valid when every call made
  # before it whose result comes later has its result before it, the message
  # at the cut is not a tool result, and the shadowed prefix holds more than
  # checkpoints. Calls without a later result (foreign or unsettled history)
  # cannot be kept together with one and never block a cut. One pass, with
  # the set of calls still waiting.
  defp valid_cuts(messages, checkpoint_id) do
    results = result_positions(messages)
    upcoming = tl(messages ++ [nil])

    messages
    |> Enum.zip(upcoming)
    |> Enum.with_index(1)
    |> Enum.reduce({MapSet.new(), false, []}, fn {{message, next}, cut}, {pending, new?, cuts} ->
      pending = track(pending, message, cut - 1, results)
      new? = new? or not checkpoint?(message, checkpoint_id)

      cuts =
        if new? and MapSet.size(pending) == 0 and not tool_result?(next),
          do: [cut | cuts],
          else: cuts

      {pending, new?, cuts}
    end)
    |> elem(2)
    |> Enum.reverse()
  end

  defp result_positions(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn
      {%Message{role: :tool, tool_call_id: id}, index}, acc when is_binary(id) ->
        Map.put(acc, id, index)

      _message, acc ->
        acc
    end)
  end

  defp track(pending, %Message{role: :assistant, tool_calls: calls}, index, results)
       when is_list(calls) do
    Enum.reduce(calls, pending, fn
      %Call{id: id}, pending when is_binary(id) ->
        case Map.fetch(results, id) do
          {:ok, result_index} when result_index > index -> MapSet.put(pending, id)
          _no_later_result -> pending
        end

      _call, pending ->
        pending
    end)
  end

  defp track(pending, %Message{role: :tool, tool_call_id: id}, _index, _results),
    do: MapSet.delete(pending, id)

  defp track(pending, _message, _index, _results), do: pending

  defp checkpoint?(_message, nil), do: false
  defp checkpoint?(%Message{id: id}, checkpoint_id), do: id == checkpoint_id

  defp tool_result?(%Message{role: :tool}), do: true
  defp tool_result?(_message), do: false

  # A retained message loses its provider continuation state (see
  # `Tackle.Lib.Compaction`), so it is measured without it.
  defp retained_size(%Message{} = message),
    do: ContextUsage.estimate_message(%{message | provider_state: nil})

  defp build(messages, cut, retained_tokens) do
    {shadowed, retained} = Enum.split(messages, cut)
    shadowed_tokens = ContextUsage.estimate_messages(shadowed)

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
      tokens_before: shadowed_tokens + ContextUsage.estimate_messages(retained),
      shadowed_tokens: shadowed_tokens,
      retained_tokens: retained_tokens
    }
  end
end
