defmodule Tackle.Session.UsageTimeline.Sample do
  @moduledoc """
  One settled assistant-generation usage observation in a durable session.
  """

  alias Tackle.Lib.Usage

  @enforce_keys [:session_id, :timestamp, :usage]
  defstruct [:session_id, :message_id, :timestamp, :usage]

  @type t :: %__MODULE__{
          session_id: String.t(),
          message_id: String.t() | nil,
          timestamp: DateTime.t(),
          usage: Usage.t()
        }
end

defmodule Tackle.Session.UsageTimeline do
  @moduledoc """
  Chronological, provider-neutral token usage derived from durable sessions.

  A timeline counts normalized usage attached to settled assistant messages.
  The current-session form covers the complete conversation archive, including
  sibling branches. Merging timelines removes exact message copies introduced
  by durable session forks, while retaining conflicting observations that happen
  to share an id.

  Records without both a timestamp and a normalized total token count are
  omitted and reflected in `:skipped_sample_count` rather than assigned an
  invented chronology.
  """

  alias Tackle.Lib.Usage
  alias Tackle.Session.Projection
  alias Tackle.Session.UsageTimeline.Sample

  @diagnostic_limit 20

  @type scope :: {:session, String.t()} | :all

  @type skipped_session :: %{session_id: String.t(), reason: term()}

  @type t :: %__MODULE__{
          scope: scope(),
          samples: [Sample.t()],
          usage: Usage.t(),
          session_count: non_neg_integer(),
          skipped_sessions: [skipped_session()],
          skipped_session_count: non_neg_integer(),
          skipped_sample_count: non_neg_integer(),
          duplicate_sample_count: non_neg_integer(),
          conflicting_sample_count: non_neg_integer()
        }

  @enforce_keys [:scope]
  defstruct scope: :all,
            samples: [],
            usage: %Usage{},
            session_count: 0,
            skipped_sessions: [],
            skipped_session_count: 0,
            skipped_sample_count: 0,
            duplicate_sample_count: 0,
            conflicting_sample_count: 0

  @doc "Returns Monday at 00:00:00 UTC for the calendar week containing `now`."
  @spec calendar_week_start(DateTime.t()) :: DateTime.t()
  def calendar_week_start(now \\ DateTime.utc_now()) do
    now = DateTime.shift_zone!(now, "Etc/UTC")
    monday = Date.add(DateTime.to_date(now), 1 - Date.day_of_week(now))
    DateTime.new!(monday, ~T[00:00:00], "Etc/UTC")
  end

  @doc "Builds a timeline from one validated durable projection."
  @spec from_projection(Projection.t(), keyword()) :: t()
  def from_projection(%Projection{session_id: session_id, messages: messages}, opts \\ []) do
    {samples, skipped} =
      Enum.reduce(messages, {[], 0}, &collect_sample(&1, &2, session_id, opts))

    samples = sort_samples(samples)

    %__MODULE__{
      scope: {:session, session_id},
      samples: samples,
      usage: aggregate(samples),
      session_count: 1,
      skipped_sample_count: skipped
    }
  end

  @doc "Merges session timelines into one chronological all-session timeline."
  @spec merge([t()], [skipped_session()]) :: t()
  def merge(timelines, skipped_sessions \\ []) when is_list(timelines) do
    samples = Enum.flat_map(timelines, & &1.samples)
    {samples, duplicates, conflicts} = deduplicate(samples)
    samples = sort_samples(samples)

    %__MODULE__{
      scope: :all,
      samples: samples,
      usage: aggregate(samples),
      session_count: Enum.sum(Enum.map(timelines, & &1.session_count)),
      skipped_sessions: Enum.take(skipped_sessions, @diagnostic_limit),
      skipped_session_count: length(skipped_sessions),
      skipped_sample_count: Enum.sum(Enum.map(timelines, & &1.skipped_sample_count)),
      duplicate_sample_count:
        duplicates + Enum.sum(Enum.map(timelines, & &1.duplicate_sample_count)),
      conflicting_sample_count:
        conflicts + Enum.sum(Enum.map(timelines, & &1.conflicting_sample_count))
    }
  end

  defp collect_sample(message, {samples, skipped}, session_id, opts) do
    case sample(message, session_id) do
      {:ok, sample} ->
        if within_range?(sample.timestamp, opts),
          do: {[sample | samples], skipped},
          else: {samples, skipped}

      :ignore ->
        {samples, skipped}

      :skip ->
        {samples, skipped + 1}
    end
  end

  defp sample(%{"role" => "assistant"} = message, session_id) do
    with {:ok, timestamp} <- timestamp(Map.get(message, "timestamp")),
         %Usage{} = usage <- Usage.normalize(Map.get(message, "token_usage")),
         total when is_integer(total) <- Usage.context_tokens(usage) do
      {:ok,
       %Sample{
         session_id: session_id,
         message_id: valid_message_id(Map.get(message, "id")),
         timestamp: timestamp,
         usage: usage
       }}
    else
      _missing_or_invalid -> :skip
    end
  end

  defp sample(_message, _session_id), do: :ignore

  defp within_range?(timestamp, opts) do
    after_start? =
      case Keyword.get(opts, :since) do
        %DateTime{} = since -> DateTime.compare(timestamp, since) in [:eq, :gt]
        _unset -> true
      end

    before_end? =
      case Keyword.get(opts, :until) do
        %DateTime{} = until -> DateTime.compare(timestamp, until) in [:eq, :lt]
        _unset -> true
      end

    after_start? and before_end?
  end

  defp timestamp(%DateTime{} = timestamp), do: {:ok, DateTime.shift_zone!(timestamp, "Etc/UTC")}

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> {:ok, timestamp}
      {:error, _reason} -> :error
    end
  end

  defp timestamp(_value), do: :error

  defp valid_message_id(id) when is_binary(id) and id != "", do: id
  defp valid_message_id(_id), do: nil

  defp aggregate(samples), do: Usage.aggregate(Enum.map(samples, & &1.usage))

  defp deduplicate(samples) do
    initial = {[], %{}, 0, MapSet.new()}

    {kept, _signatures, duplicates, conflicting_ids} =
      Enum.reduce(samples, initial, &deduplicate_sample/2)

    {kept, duplicates, MapSet.size(conflicting_ids)}
  end

  defp deduplicate_sample(%Sample{message_id: nil} = sample, state) do
    {kept, signatures, duplicates, conflicting_ids} = state
    {[sample | kept], signatures, duplicates, conflicting_ids}
  end

  defp deduplicate_sample(%Sample{message_id: message_id} = sample, state) do
    {kept, signatures, duplicates, conflicting_ids} = state
    signature = signature(sample)
    previous = Map.get(signatures, message_id, MapSet.new())

    cond do
      MapSet.member?(previous, signature) ->
        {kept, signatures, duplicates + 1, conflicting_ids}

      MapSet.size(previous) > 0 ->
        {
          [sample | kept],
          Map.put(signatures, message_id, MapSet.put(previous, signature)),
          duplicates,
          MapSet.put(conflicting_ids, message_id)
        }

      true ->
        {
          [sample | kept],
          Map.put(signatures, message_id, MapSet.put(previous, signature)),
          duplicates,
          conflicting_ids
        }
    end
  end

  defp signature(%Sample{timestamp: timestamp, usage: usage}) do
    fields = [
      :input_tokens,
      :output_tokens,
      :reasoning_tokens,
      :cache_read_tokens,
      :cache_write_tokens,
      :total_tokens,
      :cost,
      :cost_breakdown,
      :cost_estimated,
      :currency,
      :model,
      :provider
    ]

    {DateTime.to_iso8601(timestamp), Map.take(Map.from_struct(usage), fields)}
  end

  defp sort_samples(samples) do
    Enum.sort_by(samples, fn sample ->
      {
        DateTime.to_unix(sample.timestamp, :microsecond),
        sample.message_id || "",
        sample.session_id
      }
    end)
  end
end
