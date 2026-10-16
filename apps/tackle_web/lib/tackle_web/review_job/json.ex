defmodule Tackle.Web.ReviewJob.JSON do
  @moduledoc false

  @failure_fields [:failed_units, :incomplete_units, :verification_failures, :scoring_failures]

  # Partial stage failures can contain HTTP response bodies or exceptions even
  # when the overall review succeeds. Keep their locations, not provider data.
  def summary(summary) do
    summary
    |> Map.new(fn
      {field, failures} when field in @failure_fields ->
        {field, Enum.map(failures, &Map.put(&1, :reason, "review stage failed"))}

      entry ->
        entry
    end)
    |> safe()
  end

  # Normalize the remaining structured review data without invoking protocols.
  def safe(value) when is_nil(value) or is_boolean(value) or is_number(value), do: value
  def safe(value) when is_binary(value), do: String.replace_invalid(value)
  def safe(value) when is_atom(value), do: Atom.to_string(value)
  def safe(%_{} = value), do: value |> Map.from_struct() |> safe()
  def safe(value) when is_map(value), do: Map.new(value, fn {k, v} -> {key(k), safe(v)} end)
  def safe([]), do: []
  def safe([head | tail]), do: [safe(head) | safe_list(tail)]
  def safe(value) when is_tuple(value), do: value |> Tuple.to_list() |> safe()
  def safe(_unsupported), do: "[unsupported]"

  defp safe_list([]), do: []
  defp safe_list([head | tail]), do: [safe(head) | safe_list(tail)]
  defp safe_list(_tail), do: ["[unsupported tail]"]

  defp key(value) when is_atom(value), do: Atom.to_string(value)
  defp key(value) when is_binary(value), do: String.replace_invalid(value)
  defp key(_value), do: "[unsupported key]"
end
