defmodule Tackle.Review.Locations do
  @moduledoc """
  The changed lines a review finding may point at, and validation of finding
  locations against them.

  Findings must overlap a changed line (an added line on the new side, a
  removed line on the old side): comments on untouched code are rarely acted
  on. A location may still include surrounding context lines, but it must stay
  short (`max_span/0` lines).

  An index maps repository paths to their changed line ranges per side. A
  code unit may only point at its own changes (`for_unit/2`); the
  change-level unit may point at any changed line of the reviewed files.
  """

  alias Tackle.Review.{Finding, Units}

  @max_span 30
  @max_listed_paths 20

  @typedoc "Changed line ranges of one file, per side."
  @type ranges :: %{new: [Range.t()], old: [Range.t()]}

  @typedoc "Changed line ranges by repository-relative path."
  @type t :: %{optional(String.t()) => ranges()}

  @doc "Returns the largest number of lines one location may cover."
  @spec max_span() :: pos_integer()
  def max_span, do: @max_span

  @doc "Builds the index of all changed lines of the given code units."
  @spec index([Units.unit()]) :: t()
  def index(units) when is_list(units) do
    units
    |> Enum.filter(&(&1.kind == :code))
    |> Enum.reduce(%{}, fn unit, acc ->
      Map.update(acc, unit.path, unit.changed_ranges, fn ranges ->
        %{
          new: merge(ranges.new ++ unit.changed_ranges.new),
          old: merge(ranges.old ++ unit.changed_ranges.old)
        }
      end)
    end)
  end

  @doc """
  Returns the lines a unit's findings may point at: a code unit's own
  changes, or the whole `index` for the change-level unit.
  """
  @spec for_unit(Units.unit(), t()) :: t()
  def for_unit(%{kind: :code, path: path, changed_ranges: ranges}, _index), do: %{path => ranges}
  def for_unit(%{kind: :change}, index) when is_map(index), do: index

  @doc "Returns whether a location overlaps a changed line in `index`."
  @spec changed?(Finding.location(), t()) :: boolean()
  def changed?(%{path: path, side: side} = location, index) do
    case Map.fetch(index, path) do
      {:ok, ranges} -> overlaps?(Map.fetch!(ranges, side), location)
      :error -> false
    end
  end

  @doc """
  Checks a location against the allowed lines.

  Returns `{:error, message}` meant for the model: the path is not part of
  the unit, the range is longer than `max_span/0` lines, or it covers no
  changed line on its side. The message lists what is allowed.
  """
  @spec check(Finding.location(), t()) :: :ok | {:error, String.t()}
  def check(%{path: path, side: side, start_line: first, end_line: last} = location, allowed) do
    span = last - first + 1

    case Map.fetch(allowed, path) do
      :error ->
        {:error, "location.path: #{path} is not part of this review unit; use #{paths(allowed)}"}

      {:ok, _ranges} when span > @max_span ->
        {:error,
         "location: #{span} lines is too long; point at the at most #{@max_span} lines " <>
           "that show the problem"}

      {:ok, ranges} ->
        if overlaps?(Map.fetch!(ranges, side), location),
          do: :ok,
          else: {:error, no_overlap(path, side, first, last, ranges)}
    end
  end

  @doc """
  Describes the allowed lines for a prompt, one file per line, such as
  `lib/a.ex: new 3-5, 9; old 4`.
  """
  @spec describe(t()) :: String.t()
  def describe(index) when map_size(index) == 0, do: "(none)"

  def describe(index) do
    index
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join("\n", fn {path, ranges} -> "#{path}: #{describe_ranges(ranges)}" end)
  end

  defp describe_ranges(ranges) do
    [new: ranges.new, old: ranges.old]
    |> Enum.reject(fn {_side, list} -> list == [] end)
    |> Enum.map_join("; ", fn {side, list} -> "#{side} #{format_ranges(list)}" end)
  end

  defp format_ranges(ranges) do
    Enum.map_join(ranges, ", ", fn
      first..first//_ -> Integer.to_string(first)
      first..last//_ -> "#{first}-#{last}"
    end)
  end

  defp overlaps?(ranges, %{start_line: first, end_line: last}) do
    Enum.any?(ranges, fn range_first..range_last//_ ->
      range_first <= last and first <= range_last
    end)
  end

  defp no_overlap(path, side, first, last, ranges) do
    lines = if first == last, do: "line #{first}", else: "lines #{first}-#{last}"
    prefix = "location: #{side} #{lines} of #{path} contain no changed line"

    case {side, Map.fetch!(ranges, side)} do
      {:old, []} ->
        prefix <>
          "; the file has no removed lines here, use side \"new\" (#{describe_ranges(ranges)})"

      {:new, []} ->
        prefix <>
          "; the file has no added lines here, use side \"old\" (#{describe_ranges(ranges)})"

      {_side, list} ->
        prefix <> "; changed #{side} lines: #{format_ranges(list)}"
    end
  end

  defp paths(allowed) do
    {listed, rest} = allowed |> Map.keys() |> Enum.sort() |> Enum.split(@max_listed_paths)

    case {listed, rest} do
      {[], []} -> "no path (nothing in this unit changed)"
      {[path], []} -> path
      {listed, []} -> "one of " <> Enum.join(listed, ", ")
      {listed, rest} -> "one of " <> Enum.join(listed, ", ") <> " (and #{length(rest)} more)"
    end
  end

  defp merge(ranges) do
    ranges
    |> Enum.sort_by(fn first.._//_ -> first end)
    |> Enum.reduce([], fn
      first..last//_, [prev_first..prev_last//_ | rest] when first <= prev_last + 1 ->
        [prev_first..max(last, prev_last) | rest]

      range, acc ->
        [range | acc]
    end)
    |> Enum.reverse()
  end
end
