defmodule Tackle.Web.AnchorTest do
  use ExUnit.Case, async: true

  alias Tackle.Web.Anchor

  @path "lib/widget.ex"

  describe "new/4" do
    test "a single line is stored as one line, not a one-line range" do
      assert Anchor.new(@path, :new, 12) == {@path, :new, 12}
      assert Anchor.new(@path, :new, 12, 12) == {@path, :new, 12}
    end

    test "a range keeps both ends, smallest first" do
      assert Anchor.new(@path, :old, 12, 15) == {@path, :old, 12, 15}
      assert Anchor.new(@path, :old, 15, 12) == {@path, :old, 12, 15}
    end
  end

  describe "key/1" do
    test "a range hangs under its last line" do
      assert Anchor.key({@path, :new, 12, 15}) == {@path, :new, 15}
      assert Anchor.key({@path, :new, 12}) == {@path, :new, 12}
    end

    test "anything unrecognized is the general key" do
      assert Anchor.key(:general) == :general
      assert Anchor.key(nil) == :general
      assert Anchor.key({@path, :new, 0}) == :general
    end
  end

  describe "range?/1" do
    test "only a two-line anchor is a range" do
      refute Anchor.range?({@path, :new, 12})
      refute Anchor.range?(:general)
      assert Anchor.range?({@path, :new, 12, 15})
    end
  end

  describe "contains?/4" do
    test "a line inside the anchor is selected, one outside is not" do
      anchor = Anchor.new(@path, :new, 12, 15)

      assert Anchor.contains?(anchor, @path, :new, 12)
      assert Anchor.contains?(anchor, @path, :new, 15)
      assert Anchor.contains?(anchor, @path, :new, 13)
      refute Anchor.contains?(anchor, @path, :new, 11)
      refute Anchor.contains?(anchor, @path, :new, 16)
    end

    test "another file or side is never selected" do
      anchor = Anchor.new(@path, :new, 12, 15)

      refute Anchor.contains?(anchor, "lib/other.ex", :new, 13)
      refute Anchor.contains?(anchor, @path, :old, 13)
    end

    test "an absent or general anchor selects nothing" do
      refute Anchor.contains?(nil, @path, :new, 12)
      refute Anchor.contains?(:general, @path, :new, 12)
    end
  end

  describe "label/1" do
    test "names the selection the same way everywhere it is shown" do
      assert Anchor.label({@path, :new, 12}) == "line 12"
      assert Anchor.label({@path, :new, 12, 15}) == "lines 12-15"
      assert Anchor.label(:general) == "this pull request"
    end
  end

  describe "extend/4" do
    test "a shift-click below a line selects the lines between" do
      assert Anchor.extend({@path, :new, 12}, @path, :new, 15) == {@path, :new, 12, 15}
    end

    test "a shift-click above a line selects the lines between, smallest first" do
      assert Anchor.extend({@path, :new, 15}, @path, :new, 12) == {@path, :new, 12, 15}
    end

    test "extending a range picks up a line on either end" do
      range = {@path, :new, 12, 15}

      assert Anchor.extend(range, @path, :new, 10) == {@path, :new, 10, 15}
      assert Anchor.extend(range, @path, :new, 18) == {@path, :new, 12, 18}
      assert Anchor.extend(range, @path, :new, 13) == {@path, :new, 12, 15}
    end

    test "shift-clicking the same line stays a single line" do
      assert Anchor.extend({@path, :new, 12}, @path, :new, 12) == {@path, :new, 12}
    end

    test "a shift-click in another file or side starts a fresh anchor" do
      assert Anchor.extend({@path, :new, 12}, "lib/other.ex", :new, 15) ==
               {"lib/other.ex", :new, 15}

      assert Anchor.extend({@path, :new, 12}, @path, :old, 15) == {@path, :old, 15}
    end

    test "a shift-click with nothing selected yet starts a single line" do
      assert Anchor.extend(nil, @path, :new, 15) == {@path, :new, 15}
      assert Anchor.extend(:general, @path, :new, 15) == {@path, :new, 15}
    end
  end
end
