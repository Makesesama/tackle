defmodule Tackle.Web.CommandTest do
  use ExUnit.Case, async: true

  alias Tackle.Web.Command

  test "a review command with or without a profile" do
    assert Command.parse("/tackle review") == {:review, nil}
    assert Command.parse("  /tackle   review  \n") == {:review, nil}
    assert Command.parse("/tackle review quiet") == {:review, :quiet}

    assert Command.parse("/tackle review Assertive\nplease look at the cache") ==
             {:review, :assertive}
  end

  test "only the first line counts" do
    assert Command.parse("LGTM\n/tackle review") == :none
    assert Command.parse("/tackle reviewed it") == :none
    assert Command.parse("please /tackle review") == :none
    assert Command.parse("") == :none
  end

  test "malformed commands" do
    assert Command.parse("/tackle review loud") == {:error, {:unknown_profile, "loud"}}
    assert Command.parse("/tackle review quiet now") == {:error, :too_many_arguments}
  end
end
