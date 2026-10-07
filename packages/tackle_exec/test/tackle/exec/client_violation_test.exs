defmodule Tackle.Exec.ClientViolationTest do
  @moduledoc false
  # A compromised jail controls everything the exec-server sends. These tests
  # drive the client with a fake server that produces hostile frames.
  use ExUnit.Case, async: true

  import Tackle.Exec.TestSupport

  alias Tackle.Exec.Client

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  for {mode, reason} <- [
        no_hello: :expected_hello,
        oversized: {:frame_too_large, 0xFFFFFFFF},
        compressed: :compressed_term,
        trailing: :trailing_bytes,
        unknown_atom: :invalid_term,
        unknown_id: {:unexpected_reply, 999},
        second_hello: :unexpected_hello,
        amplify: :invalid_message
      ] do
    test "stops on #{mode}" do
      {:ok, client} = Client.start_link(launcher: fake_launcher(unquote(mode)))
      os_pid = os_pid(client)

      assert_receive {:EXIT, ^client, {:shutdown, {:protocol_violation, unquote(reason)}}},
                     5_000

      assert wait_until_dead(os_pid)
    end
  end

  test "stops on an unsupported protocol version" do
    {:ok, client} = Client.start_link(launcher: fake_launcher(:bad_version))

    assert_receive {:EXIT, ^client, {:shutdown, {:unsupported_protocol_version, 999}}}, 5_000
  end

  test "stops when the hello frame does not arrive in time" do
    {:ok, client} =
      Client.start_link(launcher: fake_launcher(:silent), handshake_timeout: 300)

    assert_receive {:EXIT, ^client, {:shutdown, :handshake_timeout}}, 5_000
  end

  test "stops on output beyond the granted credit and fails the command" do
    {:ok, client} = Client.start_link(launcher: fake_launcher(:credit), window: 1_000)
    {:ok, ref} = Client.exec(client, ["true"], cwd: "/")

    assert_receive {:tackle_exec, ^ref, {:data, data}}, 5_000
    assert byte_size(data) == 1_000
    assert_receive {:tackle_exec, ^ref, {:error, :exec_server_down}}, 5_000
    assert_receive {:EXIT, ^client, {:shutdown, {:protocol_violation, :credit_exceeded}}}, 5_000
  end

  test "rejects a fun in a result and fails the pending call" do
    {:ok, client} = Client.start_link(launcher: fake_launcher(:fun_result))

    assert {:error, :exec_server_down} = Client.stat(client, "/")
    assert_receive {:EXIT, ^client, {:shutdown, {:protocol_violation, :invalid_result}}}, 5_000
  end

  test "rejects a command reply for a call" do
    {:ok, client} = Client.start_link(launcher: fake_launcher(:exec_result_for_call))

    assert {:error, :exec_server_down} = Client.read(client, "/etc/hostname", 0, 1)

    assert_receive {:EXIT, ^client, {:shutdown, {:protocol_violation, {:unexpected_reply, 1}}}},
                   5_000
  end

  test "rejects a call result for a command" do
    {:ok, client} = Client.start_link(launcher: fake_launcher(:call_result_for_exec))
    {:ok, ref} = Client.exec(client, ["true"], cwd: "/")

    assert_receive {:tackle_exec, ^ref, {:error, :exec_server_down}}, 5_000

    assert_receive {:EXIT, ^client, {:shutdown, {:protocol_violation, {:unexpected_reply, 1}}}},
                   5_000
  end

  test "rejects command output for a call" do
    {:ok, client} = Client.start_link(launcher: fake_launcher(:output_for_call))

    assert {:error, :exec_server_down} = Client.stat(client, "/")

    assert_receive {:EXIT, ^client, {:shutdown, {:protocol_violation, {:unexpected_reply, 1}}}},
                   5_000
  end

  for {mode, call, reason} <- [
        {:read_too_long, :read, :invalid_result},
        {:bignum_size, :stat, :invalid_result},
        {:long_error, :stat, :invalid_message}
      ] do
    test "rejects #{mode}" do
      {:ok, client} = Client.start_link(launcher: fake_launcher(unquote(mode)))

      result =
        case unquote(call) do
          :read -> Client.read(client, "/etc/hostname", 0, 10)
          :stat -> Client.stat(client, "/")
        end

      assert result == {:error, :exec_server_down}

      assert_receive {:EXIT, ^client, {:shutdown, {:protocol_violation, unquote(reason)}}},
                     5_000
    end
  end

  test "rejects an exit status outside 0..255" do
    {:ok, client} = Client.start_link(launcher: fake_launcher(:bad_status))
    {:ok, ref} = Client.exec(client, ["true"], cwd: "/")

    assert_receive {:tackle_exec, ^ref, {:error, :exec_server_down}}, 5_000
    assert_receive {:EXIT, ^client, {:shutdown, {:protocol_violation, :invalid_message}}}, 5_000
  end

  test "stays responsive when the jail stops reading its input" do
    {:ok, client} = Client.start_link(launcher: fake_launcher(:no_read))
    data = :binary.copy("x", 1_024 * 1_024)

    # The pipe fills after the first write; the second would suspend a client
    # that blocks on the port, and it would never see the violation below.
    writes =
      for name <- ["a", "b", "c"] do
        Task.async(fn -> Client.write(client, "/tmp/" <> name, data) end)
      end

    assert_receive {:EXIT, ^client, {:shutdown, {:protocol_violation, {:unexpected_reply, 999}}}},
                   5_000

    assert Enum.map(writes, &Task.await/1) == List.duplicate({:error, :exec_server_down}, 3)
  end

  test "kills an exec-server that ignores end of input" do
    {:ok, client} = Client.start_link(launcher: fake_launcher(:ignore_eof))
    os_pid = os_pid(client)
    assert {:error, :timeout} = Client.stat(client, "/", 300)

    GenServer.stop(client, :shutdown)
    assert wait_until_dead(os_pid)
  end

  test "kills the exec-server when the client is killed brutally" do
    {:ok, client} = Client.start_link(launcher: fake_launcher(:ignore_eof))
    os_pid = os_pid(client)

    Process.exit(client, :kill)
    assert_receive {:EXIT, ^client, :killed}
    assert wait_until_dead(os_pid)
  end

  test "fails to start when the launcher cannot be spawned" do
    assert {:error, {:shutdown, {:launcher_failed, :enoent}}} =
             Client.start_link(launcher: {"/nonexistent/tackle-exec-launcher", []})
  end

  defp os_pid(client), do: :sys.get_state(client).os_pid
end
