defmodule Tackle.Exec.ProtocolTest do
  use ExUnit.Case, async: true

  alias Tackle.Exec.Protocol

  describe "decode/1" do
    test "round-trips encoded terms" do
      assert {:ok, {:out, 1, "data"}} = Protocol.decode(Protocol.encode({:out, 1, "data"}))
    end

    test "rejects compressed terms" do
      compressed = :erlang.term_to_binary({:out, 1, :binary.copy("a", 10_000)}, [:compressed])
      assert <<131, 80, _::binary>> = compressed
      assert {:error, :compressed_term} = Protocol.decode(compressed)
    end

    test "rejects trailing bytes, garbage, and unknown atoms" do
      assert {:error, :trailing_bytes} = Protocol.decode(Protocol.encode({:exit, 1, 0}) <> "x")
      assert {:error, :invalid_term} = Protocol.decode("not a term")
      assert {:error, :invalid_term} = Protocol.decode(<<131>>)
      assert {:error, :invalid_term} = Protocol.decode("")

      assert {:error, :invalid_term} =
               Protocol.decode(<<131, 119, 22, "tackle_exec_not_an_atom">>)
    end
  end

  describe "parse_message/1" do
    test "accepts the closed message set" do
      for message <- [
            {:hello, 1},
            {:out, 1, "x"},
            {:exit, 2, 0},
            {:exit, 2, 143},
            {:ok, 3, nil},
            {:error, 4, "enoent"}
          ] do
        assert {:ok, ^message} = Protocol.parse_message(message)
      end
    end

    test "rejects other shapes and executable or process terms" do
      for message <- [
            {:out, 0, "x"},
            {:out, 1, ""},
            {:out, 1, ~c"x"},
            {:out, 1, fn -> :ok end},
            {:exit, 1, -1},
            {:exit, 1, 256},
            {:exit, 1, self()},
            {:error, 1, :enoent},
            {:error, 1, :binary.copy("e", 4_097)},
            {:error, 1, make_ref()},
            {:hello, "1"},
            {:shell, 1, "rm -rf /"},
            [:out, 1, "x"]
          ] do
        assert {:error, :invalid_message} = Protocol.parse_message(message)
      end
    end
  end

  describe "parse_result/3" do
    @read %{length: 3}

    test "accepts exact result shapes" do
      read = %{data: "abc", size: 3, eof: true}
      stat = %{type: :regular, size: 3, mode: 0o100644}

      assert {:ok, ^read} = Protocol.parse_result(:read, @read, read)
      assert {:ok, nil} = Protocol.parse_result(:write, %{}, nil)
      assert {:ok, nil} = Protocol.parse_result(:delete, %{}, nil)
      assert {:ok, ^stat} = Protocol.parse_result(:stat, %{}, stat)
    end

    test "rejects extra keys, wrong types, and funs" do
      assert {:error, :invalid_result} =
               Protocol.parse_result(:read, @read, %{data: "a", size: 1, eof: true, extra: 1})

      assert {:error, :invalid_result} =
               Protocol.parse_result(:read, @read, %{data: fn -> "a" end, size: 1, eof: true})

      assert {:error, :invalid_result} =
               Protocol.parse_result(:stat, %{}, %{type: :socket, size: 1, mode: 0})

      assert {:error, :invalid_result} = Protocol.parse_result(:write, %{}, :ok)
      assert {:error, :invalid_result} = Protocol.parse_result(:stat, %{}, fn -> :ok end)
    end

    test "accepts only single path components in directory listings" do
      assert {:ok, ["a", ".hidden", "b c"]} =
               Protocol.parse_result(:list, %{}, ["a", ".hidden", "b c"])

      assert {:ok, []} = Protocol.parse_result(:list, %{}, [])

      for bad <- [["../x"], ["a/b"], [".."], ["."], [""], ["a\0"], [:a], "a"] do
        assert {:error, :invalid_result} = Protocol.parse_result(:list, %{}, bad)
      end
    end

    test "rejects more data than requested and out-of-range integers" do
      assert {:error, :invalid_result} =
               Protocol.parse_result(:read, @read, %{data: "abcd", size: 4, eof: true})

      assert {:error, :invalid_result} =
               Protocol.parse_result(:read, @read, %{
                 data: "",
                 size: Integer.pow(2, 63),
                 eof: true
               })

      assert {:error, :invalid_result} =
               Protocol.parse_result(:stat, %{}, %{type: :regular, size: 0, mode: 0o200000})

      assert {:error, :invalid_result} =
               Protocol.parse_result(:stat, %{}, %{type: :regular, size: -1, mode: 0})
    end
  end

  describe "parse_request/1" do
    test "accepts valid requests" do
      for request <- [
            {:exec, 1, %{argv: ["bash", "-c", "true"], cwd: "/w", env: [{"A", "b"}], window: 1}},
            {:signal, 1, :term},
            {:grant, 1, 10},
            {:read, 1, %{path: "a", offset: 0, length: 1}},
            {:write, 1, %{path: "a", data: "", mkdir_p: true, mode: :replace}},
            {:write, 1, %{path: "a", data: "", mkdir_p: false, mode: :append}},
            {:write, 1, %{path: "a", data: "", mkdir_p: false, mode: :create}},
            {:delete, 1, %{path: "a"}},
            {:stat, 1, %{path: "a"}},
            {:list, 1, %{path: "a"}}
          ] do
        assert {:ok, ^request} = Protocol.parse_request(request)
      end
    end

    test "rejects invalid argv, paths, and environment entries" do
      exec = fn params ->
        {:exec, 1, Map.merge(%{argv: ["true"], cwd: "/w", env: [], window: 1}, params)}
      end

      for request <- [
            exec.(%{argv: []}),
            exec.(%{argv: ["a\0b"]}),
            exec.(%{argv: [true]}),
            exec.(%{cwd: ""}),
            exec.(%{cwd: nil}),
            exec.(%{env: [{"A=B", "c"}]}),
            exec.(%{env: [{"", "c"}]}),
            exec.(%{env: [{"A", <<0xFF>>}]}),
            exec.(%{env: [{"A", "b\0"}]}),
            exec.(%{window: 0}),
            {:exec, 1, %{argv: ["true"], cwd: "/w", env: [], window: 1, extra: true}},
            {:signal, 1, :hup},
            {:grant, 1, 0},
            {:read, 0, %{path: "a", offset: 0, length: 1}},
            {:read, 1, %{path: "a", offset: -1, length: 1}},
            {:write, 1, %{path: "a", data: "", mkdir_p: "yes", mode: :replace}},
            {:write, 1, %{path: "a", data: "", mkdir_p: true}},
            {:write, 1, %{path: "a", data: "", mkdir_p: true, mode: :truncate}},
            {:delete, 1, %{path: ""}},
            {:stat, 1, %{path: "a\0"}},
            {:list, 1, %{path: ""}}
          ] do
        assert {:error, :invalid_request} = Protocol.parse_request(request)
      end
    end
  end

  test "maps known POSIX errors to atoms and keeps other reasons as binaries" do
    assert Protocol.error_reason("enoent") == :enoent
    assert Protocol.error_reason("eisdir") == :eisdir
    assert Protocol.error_reason("bash: command not found") == "bash: command not found"
    assert Protocol.wire_error(:enoent) == "enoent"
    assert Protocol.wire_error({:weird, 1}) == "{:weird, 1}"
    assert byte_size(Protocol.wire_error(:binary.copy("e", 5_000))) == 4_096
  end
end
