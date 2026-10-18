defmodule Tackle.Elixir.ProjectNode.ProtocolTest do
  use ExUnit.Case, async: true

  alias Tackle.Elixir.Diagnostic
  alias Tackle.Elixir.ProjectNode.Protocol

  @diagnostic %{
    severity: :error,
    file: "/work/lib/a.ex",
    line: 3,
    column: 17,
    message: "undefined function missing/0",
    compiler: "Elixir"
  }

  defp result(overrides \\ %{}) do
    Map.merge(
      %{status: :error, diagnostics: [@diagnostic], output: "", duration_ms: 5},
      overrides
    )
  end

  test "encodes requests as length-prefixed frames" do
    <<size::32, payload::binary>> = Protocol.encode_request(7, {:compile, "/work"})
    assert size == byte_size(payload)
    assert {:ok, {:request, 7, {:compile, "/work"}}} = Protocol.decode(payload)
  end

  test "accepts the closed message set" do
    for message <- [{:hello, 1}, {:reply, 1, {:ok, %{}}}, {:reply, 2, {:error, "boom"}}] do
      assert {:ok, ^message} = Protocol.parse_message(message)
    end

    for message <- [
          {:reply, 0, {:ok, nil}},
          {:reply, 1, {:error, :atom}},
          {:reply, 1, {:error, :binary.copy("x", 8_193)}},
          {:reply, 1, :ok},
          {:out, 1, "x"},
          :hello
        ] do
      assert {:error, :invalid_message} = Protocol.parse_message(message), inspect(message)
    end
  end

  test "converts a valid compile result" do
    assert {:ok, %{status: :error, diagnostics: [diagnostic], output: "", duration_ms: 5}} =
             Protocol.parse_result({:compile, "/work"}, result())

    assert %Diagnostic{severity: :error, file: "/work/lib/a.ex", line: 3, column: 17} = diagnostic

    nils = %{@diagnostic | file: nil, line: nil, column: nil, compiler: nil}

    assert {:ok, %{diagnostics: [%Diagnostic{file: nil, line: nil}]}} =
             Protocol.parse_result({:compile, "/work"}, result(%{diagnostics: [nils]}))
  end

  test "replaces invalid UTF-8 in text" do
    bad = %{@diagnostic | message: <<"bad ", 255>>}

    assert {:ok, %{diagnostics: [%Diagnostic{message: message}], output: output}} =
             Protocol.parse_result(
               {:compile, "/w"},
               result(%{diagnostics: [bad], output: <<255>>})
             )

    assert String.valid?(message) and String.valid?(output)
  end

  test "rejects results outside the closed shape" do
    invalid_diagnostics = [
      %{@diagnostic | severity: :fatal},
      %{@diagnostic | file: "lib/relative.ex"},
      %{@diagnostic | file: "/a\0b"},
      %{@diagnostic | line: -1},
      %{@diagnostic | line: "3"},
      %{@diagnostic | message: :binary.copy("x", 4_001)},
      %{@diagnostic | message: ~c"chars"},
      %{@diagnostic | compiler: :binary.copy("x", 101)},
      Map.put(@diagnostic, :extra, true),
      Map.delete(@diagnostic, :column),
      {:diagnostic, @diagnostic}
    ]

    for diagnostic <- invalid_diagnostics do
      assert {:error, :invalid_result} =
               Protocol.parse_result({:compile, "/w"}, result(%{diagnostics: [diagnostic]})),
             inspect(diagnostic)
    end

    for overrides <- [
          %{status: :failed},
          %{output: :binary.copy("x", 65_537)},
          %{duration_ms: -1},
          %{diagnostics: List.duplicate(@diagnostic, 1_001)},
          %{diagnostics: :none},
          %{extra: 1}
        ] do
      assert {:error, :invalid_result} =
               Protocol.parse_result({:compile, "/w"}, result(overrides)),
             inspect(Map.keys(overrides))
    end

    assert {:error, :invalid_result} = Protocol.parse_result({:compile, "/w"}, nil)
  end
end
