defmodule Tackle.Review.LocationsTest do
  use ExUnit.Case, async: true

  alias Tackle.Review.Locations

  defp code_unit(path, new, old \\ []) do
    %{kind: :code, id: "#{path}#1", path: path, changed_ranges: %{new: new, old: old}}
  end

  defp location(path, side, first, last),
    do: %{path: path, side: side, start_line: first, end_line: last}

  test "index merges the changed ranges of a file's units and ignores the change unit" do
    units = [
      %{kind: :change, id: "change"},
      code_unit("lib/a.ex", [3..5], [4..4]),
      code_unit("lib/a.ex", [6..8, 20..20], []),
      code_unit("lib/b.ex", [1..2])
    ]

    assert Locations.index(units) == %{
             "lib/a.ex" => %{new: [3..8, 20..20], old: [4..4]},
             "lib/b.ex" => %{new: [1..2], old: []}
           }
  end

  test "a code unit allows only its own changes; the change unit allows the whole index" do
    unit = code_unit("lib/a.ex", [3..5])
    index = Locations.index([unit, code_unit("lib/b.ex", [1..1])])

    assert Locations.for_unit(unit, index) == %{"lib/a.ex" => %{new: [3..5], old: []}}
    assert Locations.for_unit(%{kind: :change}, index) == index
  end

  test "check accepts locations overlapping a changed line on their side" do
    allowed = %{"lib/a.ex" => %{new: [10..12], old: [7..7]}}

    assert :ok = Locations.check(location("lib/a.ex", :new, 8, 10), allowed)
    assert :ok = Locations.check(location("lib/a.ex", :new, 12, 14), allowed)
    assert :ok = Locations.check(location("lib/a.ex", :old, 7, 7), allowed)
    assert Locations.changed?(location("lib/a.ex", :new, 11, 11), allowed)
    refute Locations.changed?(location("lib/a.ex", :new, 13, 20), allowed)
    refute Locations.changed?(location("lib/other.ex", :new, 11, 11), allowed)
  end

  test "check explains what is wrong" do
    allowed = %{"lib/a.ex" => %{new: [10..12, 15..15], old: []}}

    assert {:error, message} = Locations.check(location("lib/b.ex", :new, 1, 1), allowed)
    assert message =~ "location.path: lib/b.ex is not part of this review unit; use lib/a.ex"

    assert {:error, message} = Locations.check(location("lib/a.ex", :new, 1, 40), allowed)
    assert message =~ "40 lines is too long"

    assert {:error, message} = Locations.check(location("lib/a.ex", :new, 13, 14), allowed)
    assert message =~ "new lines 13-14 of lib/a.ex contain no changed line"
    assert message =~ "changed new lines: 10-12, 15"

    assert {:error, message} = Locations.check(location("lib/a.ex", :old, 11, 11), allowed)
    assert message =~ "use side \"new\""
  end

  test "describe lists the allowed lines per file" do
    index = %{
      "lib/b.ex" => %{new: [], old: [2..3]},
      "lib/a.ex" => %{new: [3..5, 9..9], old: [4..4]}
    }

    assert Locations.describe(index) == "lib/a.ex: new 3-5, 9; old 4\nlib/b.ex: old 2-3"
    assert Locations.describe(%{}) == "(none)"
  end
end
