defmodule Tackle.CLI.HerdrTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.Herdr
  alias Tackle.CLI.Parser

  @config %{pane_id: "w1:p2", socket_path: "/tmp/herdr.sock"}

  describe "config/1" do
    test "reads the pane and socket inside Herdr" do
      env = %{
        "HERDR_ENV" => "1",
        "HERDR_PANE_ID" => "w1:p2",
        "HERDR_SOCKET_PATH" => "/tmp/herdr.sock"
      }

      assert Herdr.config(env) == {:ok, @config}
    end

    test "is disabled outside Herdr or without a pane and socket" do
      base = %{"HERDR_ENV" => "1", "HERDR_PANE_ID" => "w1:p2", "HERDR_SOCKET_PATH" => "/s"}

      for env <- [
            %{},
            Map.delete(base, "HERDR_ENV"),
            Map.put(base, "HERDR_ENV", "0"),
            Map.delete(base, "HERDR_PANE_ID"),
            Map.put(base, "HERDR_PANE_ID", ""),
            Map.delete(base, "HERDR_SOCKET_PATH"),
            Map.put(base, "HERDR_SOCKET_PATH", "")
          ] do
        assert Herdr.config(env) == :disabled
      end
    end
  end

  describe "requests" do
    test "a state report without a session carries only the state" do
      assert Herdr.report_request(
               @config,
               %{state: :working, session_id: nil, resume_argv: nil},
               7
             ) ==
               %{
                 "id" => "tackle:7",
                 "method" => "pane.report_agent",
                 "params" => %{
                   "pane_id" => "w1:p2",
                   "source" => "tackle",
                   "agent" => "tackle",
                   "state" => "working",
                   "seq" => 7
                 }
               }
    end

    test "a resumable report carries the session and its resume command" do
      report = %{state: :idle, session_id: "s-1", resume_argv: Herdr.resume_argv("s-1")}

      assert %{"params" => params} = Herdr.report_request(@config, report, 8)
      assert params["state"] == "idle"
      assert params["agent_session_id"] == "s-1"
      assert params["resume_argv"] == ["tackle", "--resume", "s-1"]
    end

    test "a release names the pane, source, and agent" do
      assert Herdr.release_request(@config, 9) == %{
               "id" => "tackle:9",
               "method" => "pane.release_agent",
               "params" => %{
                 "pane_id" => "w1:p2",
                 "source" => "tackle",
                 "agent" => "tackle",
                 "seq" => 9
               }
             }
    end
  end

  test "the resume command reopens the session in the shell" do
    ["tackle" | args] = Herdr.resume_argv("session-1")

    assert {:ok, {:run, %{resume: "session-1", abandon: false, prompt: nil}}} =
             Parser.parse(args)
  end

  test "sequences follow the clock and always increase" do
    first = Herdr.next_seq(0)
    assert first >= System.os_time(:microsecond) - 1_000_000
    assert Herdr.next_seq(first + 1_000_000_000) == first + 1_000_000_001
  end

  describe "send_request/3" do
    setup do
      path = Path.join(System.tmp_dir!(), "herdr-test-#{System.unique_integer([:positive])}.sock")
      on_exit(fn -> File.rm(path) end)
      %{config: %{@config | socket_path: path}}
    end

    test "sends one JSON line and accepts a success reply", %{config: config} do
      serve(config.socket_path, ~s({"id":"tackle:1","result":{"type":"ok"}}\n))
      request = Herdr.release_request(config, 1)

      assert Herdr.send_request(config, request) == :ok
      assert_receive {:herdr_request, line}
      assert JSON.decode!(line) == request
    end

    test "returns Herdr's error code", %{config: config} do
      serve(
        config.socket_path,
        ~s({"id":"tackle:1","error":{"code":"pane_not_found","message":"no pane"}}\n)
      )

      assert Herdr.send_request(config, Herdr.release_request(config, 1)) ==
               {:error, {:herdr, "pane_not_found", "no pane"}}
    end

    test "rejects a reply that is not JSON", %{config: config} do
      serve(config.socket_path, "nope\n")

      assert {:error, {:invalid_reply, _reason}} =
               Herdr.send_request(config, Herdr.release_request(config, 1))
    end

    test "times out when Herdr does not answer", %{config: config} do
      serve(config.socket_path, nil)

      assert Herdr.send_request(config, Herdr.release_request(config, 1), 50) ==
               {:error, :timeout}
    end

    test "fails without a listening socket", %{config: config} do
      assert {:error, _reason} = Herdr.send_request(config, Herdr.release_request(config, 1))
    end

    test "returns an error for a socket path the platform cannot address" do
      config = %{@config | socket_path: String.duplicate("a", 200)}

      assert Herdr.send_request(config, Herdr.release_request(config, 1)) ==
               {:error, :invalid_socket_path}
    end
  end

  # Accepts one connection on a local socket, forwards the request line to the
  # test, and answers with `reply` (or keeps silent when it is nil).
  defp serve(path, reply) do
    test_pid = self()
    options = [:binary, packet: :line, active: false, ifaddr: {:local, path}]
    {:ok, listener} = :gen_tcp.listen(0, options)

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, line} = :gen_tcp.recv(socket, 0)
        send(test_pid, {:herdr_request, line})
        if reply, do: :ok = :gen_tcp.send(socket, reply)

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(pid, :stop) end)
  end
end
