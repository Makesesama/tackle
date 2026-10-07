defmodule Tackle.Exec.FakeServer do
  @moduledoc false
  # A misbehaving exec-server used to test host-side protocol enforcement.
  # It writes raw bytes so it can produce frames the real server never would.

  alias Tackle.Exec.{Framer, Protocol}

  def main([:no_read]) do
    # Never read standard input, so the host's writes back up, then send a
    # violation the host must still notice.
    Process.group_leader(self(), Process.whereis(:standard_error))
    {:ok, out} = :file.open(~c"/dev/fd/1", [:write, :raw, :binary])
    write_raw(out, Protocol.encode(Protocol.hello()))
    Process.sleep(500)
    write_raw(out, Protocol.encode({:exit, 999, 0}))
    Process.sleep(:infinity)
  end

  def main([mode]) do
    Process.group_leader(self(), Process.whereis(:standard_error))
    io = Port.open({:fd, 0, 1}, [:binary, :eof])
    run(mode, io)
    wait_for_eof(io, Framer.new(1_000_000))
  end

  defp write_raw(out, payload),
    do: :ok = :file.write(out, <<byte_size(payload)::32, payload::binary>>)

  defp run(:silent, _io), do: :ok
  defp run(:no_hello, io), do: frame(io, {:exit, 1, 0})
  defp run(:bad_version, io), do: frame(io, {:hello, 999})

  defp run(:ignore_eof, io) do
    hello(io)
    Process.sleep(:infinity)
  end

  defp run(:oversized, io) do
    hello(io)
    Port.command(io, <<0xFFFFFFFF::32, "x">>)
  end

  defp run(:compressed, io) do
    hello(io)
    raw(io, :erlang.term_to_binary({:exit, 1, :binary.copy("a", 10_000)}, [:compressed]))
  end

  defp run(:trailing, io) do
    hello(io)
    raw(io, Protocol.encode({:exit, 1, 0}) <> "junk")
  end

  defp run(:unknown_atom, io) do
    hello(io)
    raw(io, <<131, 119, 22, "tackle_exec_not_an_atom">>)
  end

  defp run(:unknown_id, io) do
    hello(io)
    frame(io, {:exit, 999, 0})
  end

  defp run(:second_hello, io) do
    hello(io)
    hello(io)
  end

  defp run(:credit, io) do
    hello(io)
    {:exec, id, %{window: window}} = next_request(io)
    frame(io, {:out, id, :binary.copy("x", window)})
    frame(io, {:out, id, "y"})
  end

  defp run(:fun_result, io) do
    hello(io)
    {:stat, id, _params} = next_request(io)
    frame(io, {:ok, id, fn -> :pwned end})
  end

  defp run(:exec_result_for_call, io) do
    hello(io)
    {:read, id, _params} = next_request(io)
    frame(io, {:exit, id, 0})
  end

  defp run(:call_result_for_exec, io) do
    hello(io)
    {:exec, id, _params} = next_request(io)
    frame(io, {:ok, id, nil})
  end

  defp run(:output_for_call, io) do
    hello(io)
    {:stat, id, _params} = next_request(io)
    frame(io, {:out, id, "x"})
  end

  defp run(:read_too_long, io) do
    hello(io)
    {:read, id, %{length: length}} = next_request(io)
    frame(io, {:ok, id, %{data: :binary.copy("x", length + 1), size: length + 1, eof: true}})
  end

  defp run(:bignum_size, io) do
    hello(io)
    {:stat, id, _params} = next_request(io)
    frame(io, {:ok, id, %{type: :regular, size: Integer.pow(2, 64), mode: 0}})
  end

  defp run(:bad_status, io) do
    hello(io)
    {:exec, id, _params} = next_request(io)
    frame(io, {:exit, id, 256})
  end

  defp run(:long_error, io) do
    hello(io)
    {:stat, id, _params} = next_request(io)
    frame(io, {:error, id, :binary.copy("e", 4_097)})
  end

  # A list of `[]` costs one byte per element on the wire and two words when
  # decoded. The host must stay within its limits and reject it cleanly.
  defp run(:amplify, io) do
    hello(io)
    count = 2 * 1_024 * 1_024 - 16
    raw(io, <<131, 108, count::32>> <> :binary.copy(<<106>>, count) <> <<106>>)
  end

  defp hello(io), do: frame(io, Protocol.hello())
  defp frame(io, term), do: raw(io, Protocol.encode(term))
  defp raw(io, payload), do: Port.command(io, <<byte_size(payload)::32, payload::binary>>)

  defp next_request(io), do: next_request(io, Framer.new(16_000_000))

  defp next_request(io, framer) do
    receive do
      {^io, {:data, data}} ->
        case Framer.push(framer, data) do
          {:ok, [frame | _], _framer} ->
            {:ok, request} = Protocol.decode(frame)
            request

          {:ok, [], framer} ->
            next_request(io, framer)
        end

      {^io, :eof} ->
        System.halt(0)
    end
  end

  defp wait_for_eof(io, framer) do
    receive do
      {^io, {:data, _data}} -> wait_for_eof(io, framer)
      {^io, :eof} -> System.halt(0)
    end
  end
end
