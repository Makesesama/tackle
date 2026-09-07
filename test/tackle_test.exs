defmodule TackleTest do
  use ExUnit.Case
  doctest Tackle

  test "greets the world" do
    assert Tackle.hello() == :world
  end
end
