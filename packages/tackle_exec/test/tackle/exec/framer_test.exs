defmodule Tackle.Exec.FramerTest do
  use ExUnit.Case, async: true

  alias Tackle.Exec.Framer

  test "returns complete frames and buffers partial ones" do
    framer = Framer.new(100)
    data = <<3::32, "abc", 2::32, "de", 4::32, "f">>

    assert {:ok, ["abc", "de"], framer} = Framer.push(framer, data)
    assert {:ok, [], framer} = Framer.push(framer, "gh")
    assert {:ok, ["fghi"], _framer} = Framer.push(framer, "i")
  end

  test "reassembles headers and bodies split across many chunks" do
    payload = :binary.copy("z", 1_000)
    bytes = <<byte_size(payload)::32, payload::binary>>

    {frames, _framer} =
      for <<byte <- bytes>>, reduce: {[], Framer.new(2_000)} do
        {frames, framer} ->
          {:ok, new, framer} = Framer.push(framer, <<byte>>)
          {frames ++ new, framer}
      end

    assert frames == [payload]
  end

  test "rejects an oversized header before buffering the body" do
    assert {:error, {:frame_too_large, 101}} = Framer.push(Framer.new(100), <<101::32>>)

    assert {:error, {:frame_too_large, 0xFFFFFFFF}} =
             Framer.push(Framer.new(100), <<0xFFFFFFFF::32, "x">>)
  end

  test "accepts a frame of exactly the maximum and rejects one byte more" do
    assert {:ok, [], framer} = Framer.push(Framer.new(5), <<0, 0>>)
    assert {:ok, ["abcde"], _framer} = Framer.push(framer, <<0, 5, "abcde">>)

    assert {:ok, [], framer} = Framer.push(Framer.new(5), <<0, 0, 0>>)
    assert {:error, {:frame_too_large, 6}} = Framer.push(framer, <<6>>)
  end

  test "accepts empty frames and empty pushes" do
    assert {:ok, [], framer} = Framer.push(Framer.new(10), "")
    assert {:ok, [""], _framer} = Framer.push(framer, <<0::32>>)
  end
end
