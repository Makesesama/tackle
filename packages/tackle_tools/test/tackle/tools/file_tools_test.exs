defmodule Tackle.Tools.FileToolsTest do
  alias Tackle.Tools.Test.Executors

  use ExUnit.Case, async: true, parameterize: Executors.parameters()

  import Executors, only: [start_executor: 1]

  alias Tackle.Lib.Cancellation
  alias Tackle.Tools.{Bash, Edit, Output, Read, Write}

  setup :start_executor

  setup %{executor: executor} do
    directory =
      Path.join(
        System.tmp_dir!(),
        "tackle-tools-test-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{context: %{cwd: directory, executor: executor}, directory: directory}
  end

  test "write creates parents and read resolves paths from the context cwd", %{
    context: context,
    directory: directory
  } do
    assert {:ok, "Successfully wrote to nested/example.txt"} =
             Write.run(%{"path" => "nested/example.txt", "content" => "one\ntwo\nthree"}, context)

    assert File.read!(Path.join(directory, "nested/example.txt")) == "one\ntwo\nthree"

    assert {:ok, "two\n\n[1 more lines in file. Use offset=3 to continue.]"} =
             Read.run(%{"path" => "nested/example.txt", "offset" => 2, "limit" => 1}, context)
  end

  test "read rejects invalid ranges and reports truncation", %{
    context: context,
    directory: directory
  } do
    path = Path.join(directory, "large.txt")
    File.write!(path, Enum.map_join(1..2_001, "\n", &"line #{&1}"))

    assert {:error, "offset must be a positive integer"} =
             Read.run(%{"path" => "large.txt", "offset" => 0}, context)

    assert {:ok, output} = Read.run(%{"path" => "large.txt"}, context)
    assert output =~ "line 1\n"
    assert output =~ "[Showing lines 1-2000 of 2001. Use offset=2001 to continue.]"
    refute output =~ "line 2001\n"
  end

  test "edit applies disjoint replacements against the original file and preserves CRLF", %{
    context: context,
    directory: directory
  } do
    path = Path.join(directory, "example.txt")
    File.write!(path, <<0xEF, 0xBB, 0xBF>> <> "alpha\r\nbeta\r\ngamma\r\n")

    edits = [
      %{"oldText" => "alpha\nbeta", "newText" => "first\nsecond"},
      %{"oldText" => "gamma", "newText" => "third"}
    ]

    assert {:ok, "Successfully replaced 2 block(s) in example.txt."} =
             Edit.run(%{"path" => "example.txt", "edits" => edits}, context)

    assert File.read!(path) == <<0xEF, 0xBB, 0xBF>> <> "first\r\nsecond\r\nthird\r\n"
  end

  test "edit rejects ambiguous and overlapping replacements without changing the file", %{
    context: context,
    directory: directory
  } do
    path = Path.join(directory, "example.txt")
    File.write!(path, "same same")

    assert {:error, message} =
             Edit.run(
               %{
                 "path" => "example.txt",
                 "edits" => [%{"oldText" => "same", "newText" => "different"}]
               },
               context
             )

    assert message =~ "Found 2 occurrences"
    assert File.read!(path) == "same same"

    File.write!(path, "abcdef")

    assert {:error, message} =
             Edit.run(
               %{
                 "path" => "example.txt",
                 "edits" => [
                   %{"oldText" => "abcd", "newText" => "first"},
                   %{"oldText" => "cdef", "newText" => "second"}
                 ]
               },
               context
             )

    assert message =~ "overlap"
    assert File.read!(path) == "abcdef"
  end

  test "retains the valid UTF-8 tail of oversized single-line output" do
    output = String.duplicate("é", 30_000)
    result = Output.tail(output)

    assert result.truncated?
    assert result.truncated_by == :bytes
    assert result.output_lines == 1
    assert byte_size(result.content) <= Output.max_bytes()
    assert String.valid?(result.content)
  end

  test "bash returns combined output, uses the context cwd, and reports failures", %{
    context: context,
    directory: directory
  } do
    File.write!(Path.join(directory, "value.txt"), "workspace")

    assert {:ok, "workspaceerror"} =
             Bash.run(
               %{"command" => "printf \"$(cat value.txt)\"; printf error >&2"},
               context
             )

    assert {:error, failure} = Bash.run(%{"command" => "printf failed; exit 7"}, context)
    assert failure == "failed\n\nCommand exited with code 7"
  end

  test "bash stores full truncated output in a private, random, exclusively-created file", %{
    context: context
  } do
    byte_count = Output.max_bytes() + 1
    assert {:ok, output} = Bash.run(%{"command" => "printf 'x%.0s' {1..#{byte_count}}"}, context)
    assert [_, path] = Regex.run(~r/Full output: ([^\]]+)\]\z/, output)

    on_exit(fn -> File.rm(path) end)

    assert File.read!(path) == String.duplicate("x", byte_count)
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert Path.basename(path) =~ ~r/^tackle-bash-[A-Za-z0-9_-]{22}\.log$/
  end

  test "bash honors timeout and cooperative cancellation", %{context: context} do
    assert {:error, "Command timed out"} =
             Bash.run(%{"command" => "sleep 5", "timeout" => 0.05}, context)

    signal = Cancellation.new_signal()
    cancelling_context = Map.put(context, :cancellation_signal, signal)
    task = Task.async(fn -> Bash.run(%{"command" => "sleep 5"}, cancelling_context) end)

    Process.sleep(50)
    assert :ok = Cancellation.cancel(signal, :test_cancelled)
    assert {:error, "Command aborted"} = Task.await(task, 1_000)
    Cancellation.delete(signal)
  end
end
