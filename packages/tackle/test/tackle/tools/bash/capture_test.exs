defmodule Tackle.Tools.Bash.CaptureTest do
  use ExUnit.Case, async: true

  alias Tackle.Tools.Bash.Capture
  alias Tackle.Tools.Output

  test "retains bounded state while spooling repeated large chunks" do
    chunk = :binary.copy("é\n", 10_000)

    state =
      Enum.reduce(1..100, Capture.new(), fn _, state ->
        next = Capture.append(state, chunk)
        assert byte_size(next.tail) <= Output.max_bytes() * 4
        assert byte_size(next.prefix) <= Output.max_bytes()
        next
      end)

    on_exit(fn -> File.rm(state.path) end)
    result = Capture.finish(state)
    assert result =~ "Showing lines 998001-1000000 of 1000000."
    assert File.stat!(state.path).size == byte_size(chunk) * 100
    assert Bitwise.band(File.stat!(state.path).mode, 0o777) == 0o600
  end

  test "matches the original tail selection regardless of chunking" do
    samples = [
      "",
      "\n",
      "one\ntwo\n",
      :binary.copy("x\n", 2_000),
      :binary.copy("x\n", 2_001),
      :binary.copy("x", 210_000) <> "\n",
      :binary.copy("x", 210_000) <> "\nshort\n",
      :binary.copy("é\n", 80_000) <> "last",
      :binary.copy("x\n", 80_000) <> :binary.copy("é", 40_000)
    ]

    for sample <- samples do
      state =
        sample
        |> String.codepoints()
        |> Enum.chunk_every(4_097)
        |> Enum.reduce(Capture.new(), fn chunk, state ->
          Capture.append(state, Enum.join(chunk))
        end)

      on_exit(fn -> if state.path, do: File.rm(state.path) end)
      result = Capture.finish(state)
      expected = Output.tail(sample)

      cond do
        sample == "" ->
          assert result == "(no output)"

        not expected.truncated? ->
          assert result == expected.content

        true ->
          start_line = expected.total_lines - expected.output_lines + 1

          assert result ==
                   expected.content <>
                     "\n\n[Showing lines #{start_line}-#{expected.total_lines} of #{expected.total_lines}. Full output: #{state.path}]"

          assert File.read!(state.path) == sample
      end
    end
  end

  test "discard closes and removes the spill file" do
    state = Capture.append(Capture.new(), :binary.copy("x", Output.max_bytes() + 1))
    assert File.exists?(state.path)
    assert :ok = Capture.discard(state)
    refute File.exists?(state.path)
    assert {:error, _} = :file.write(state.file, "later")
  end

  test "a write failure removes the incomplete file but preserves bounded output" do
    state = Capture.append(Capture.new(), :binary.copy("x", Output.max_bytes() + 1))
    File.close(state.file)
    next = Capture.append(state, "last")
    refute File.exists?(state.path)
    assert next.spill_failed?
    refute Capture.finish(next) =~ "Full output:"
  end
end
