defmodule Tackle.Review.Cluster do
  @moduledoc """
  Merges findings that describe the same problem.

  Two findings describe the same problem when they cite the same rule (or,
  without a rule, have the same category) and their locations overlap: the
  same path and side, with intersecting line ranges. Findings with the same
  fingerprint are merged as well.

  Input is grouped by sample (one list per detector run). A cluster keeps
  its clearest member, the one with the highest confidence (then the
  shortest body), and its `support` is the number of samples that reported
  it, so a problem reported twice by one run still counts once.
  """

  alias Tackle.Review.Finding

  @doc "Merges the findings of all samples; clusters are in order of first appearance."
  @spec merge([[Finding.t()]]) :: [Finding.t()]
  def merge(samples) when is_list(samples) do
    samples
    |> Enum.with_index()
    |> Enum.flat_map(fn {findings, sample} -> Enum.map(findings, &{&1, sample}) end)
    |> Enum.reduce([], &add/2)
    |> Enum.reverse()
    |> Enum.map(fn {finding, sample_ids} ->
      %{finding | support: MapSet.size(sample_ids)}
    end)
  end

  @doc "Returns whether two findings describe the same problem."
  @spec same?(Finding.t(), Finding.t()) :: boolean()
  def same?(%Finding{} = a, %Finding{} = b) do
    (a.fingerprint != nil and a.fingerprint == b.fingerprint) or
      (key(a) == key(b) and overlap?(a.location, b.location))
  end

  # Clusters are kept newest first as `{representative, sample_ids}`.
  defp add({finding, sample}, clusters) do
    case Enum.find_index(clusters, fn {representative, _ids} -> same?(representative, finding) end) do
      nil ->
        [{finding, MapSet.new([sample])} | clusters]

      index ->
        List.update_at(clusters, index, fn {representative, ids} ->
          {clearer(representative, finding), MapSet.put(ids, sample)}
        end)
    end
  end

  @doc """
  Returns the clearer of two findings of one cluster: the one with the
  higher confidence, then the shorter body; `current` on a tie.
  """
  @spec clearer(Finding.t(), Finding.t()) :: Finding.t()
  def clearer(%Finding{} = current, %Finding{} = candidate) do
    if rank(candidate) > rank(current), do: candidate, else: current
  end

  defp rank(%Finding{confidence: confidence, body: body}), do: {confidence, -String.length(body)}

  defp key(%Finding{rule_id: nil, category: category}), do: {:category, category}
  defp key(%Finding{rule_id: rule_id}), do: {:rule, rule_id}

  defp overlap?(a, b) do
    a.path == b.path and a.side == b.side and a.start_line <= b.end_line and
      b.start_line <= a.end_line
  end
end
