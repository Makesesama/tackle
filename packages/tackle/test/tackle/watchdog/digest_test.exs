defmodule Tackle.Watchdog.DigestTest do
  use ExUnit.Case, async: true

  alias Tackle.Watchdog.Digest

  test "reports elapsed time, output rate, and silence" do
    digest =
      "make test"
      |> Digest.new(0)
      |> Digest.append("compiling\n", 1_000)
      |> Digest.append("", 9_000)

    assert %{
             "command" => "make test",
             "elapsed_seconds" => 10.0,
             "output_bytes" => 10,
             "output_bytes_per_second" => 1.0,
             "seconds_since_last_output" => 9.0,
             "output_tail" => "compiling\n"
           } = Digest.state(digest, 10_000)
  end

  test "a silent command has been silent since it started" do
    assert %{"seconds_since_last_output" => 4.0, "output_tail" => ""} =
             "sleep 100" |> Digest.new(0) |> Digest.state(4_000)
  end

  test "keeps a bounded tail of valid UTF-8 while counting every byte" do
    digest =
      Enum.reduce(1..3_000, Digest.new("loop", 0), fn _i, digest ->
        Digest.append(digest, "ü", 1)
      end)

    assert digest.bytes == 6_000
    assert byte_size(digest.tail) <= 4_096
    assert String.valid?(digest.tail)
  end

  test "cleans terminal escapes and carriage-return redraws from the tail" do
    digest =
      "download"
      |> Digest.new(0)
      |> Digest.append("\e[32mok\e[0m\r\n 10%\r 50%\r100%\ndone", 1)

    assert Digest.state(digest, 2)["output_tail"] == "ok\n100%\ndone"
  end

  test "repetition ignores digits so counting loops look repetitive" do
    loop = Enum.map(1..20, &"tick #{&1}")
    build = Enum.map(1..20, &"compiling module_#{<<?a + rem(&1, 26)>>}.ex")

    assert Digest.repetition(loop) >= 0.9
    assert Digest.repetition(build) < 0.1
    assert Digest.repetition(["a", "a", "a"]) == 0.0
  end

  test "long commands are truncated" do
    command = String.duplicate("x", 3_000)
    state = command |> Digest.new(0) |> Digest.state(1)
    assert byte_size(state["command"]) < 3_000
    assert String.ends_with?(state["command"], "…")
  end
end
