defmodule Tackle.CLI.Herdr do
  @moduledoc """
  Reports the interactive shell's agent state to a [Herdr](https://herdr.dev)
  pane.

  Herdr is a terminal multiplexer for coding agents. Every process in a Herdr
  pane inherits `HERDR_ENV=1`, `HERDR_PANE_ID`, and `HERDR_SOCKET_PATH`; an
  agent that reports through that socket gets its name and `idle`/`working`
  state in Herdr's sidebar, completion notifications, `herdr agent wait`, and
  its session reopened in the same pane after a Herdr server restart. See
  Herdr's "Add Herdr support to your agent" guide.

  This module owns the wire contract: reading the pane from the environment,
  building `pane.report_agent` and `pane.release_agent` requests, and sending
  one request over Herdr's local socket as a newline-terminated JSON object
  answered by one JSON line. Outside Herdr `config/1` returns `:disabled` and
  nothing is reported. Deciding *when* to report belongs to
  `Tackle.CLI.Herdr.Reporter` and the shell.

  The socket is a Unix domain socket, so reporting is available where
  `:gen_tcp` supports local addresses.
  """

  @source "tackle"
  @agent "tackle"
  # Herdr's socket is local and answers at once; a request that takes longer
  # is abandoned rather than holding up the shell's report or its exit.
  @timeout 500
  # Herdr answers with one short JSON line; anything longer is not a reply.
  @max_response_bytes 65_536

  @typedoc "Where to report: the pane this process runs in and Herdr's socket."
  @type config :: %{pane_id: String.t(), socket_path: String.t()}

  @typedoc """
  The shell's reportable state.

  `session_id` and `resume_argv` are set together once the session can be
  resumed; Herdr runs `resume_argv` in the pane after a server restart.
  """
  @type report :: %{
          state: :idle | :working,
          session_id: String.t() | nil,
          resume_argv: [String.t()] | nil
        }

  @typedoc "A request ready to send with `send_request/2`."
  @type request :: %{required(String.t()) => term()}

  @doc """
  Reads the Herdr pane from `env`, or returns `:disabled` outside Herdr.

  Reporting needs `HERDR_ENV=1` and non-empty `HERDR_PANE_ID` and
  `HERDR_SOCKET_PATH`; anything else means the process is not in a Herdr pane.
  """
  @spec config(%{optional(String.t()) => String.t()}) :: {:ok, config()} | :disabled
  def config(env \\ System.get_env()) when is_map(env) do
    with "1" <- Map.get(env, "HERDR_ENV"),
         pane_id when is_binary(pane_id) and pane_id != "" <- Map.get(env, "HERDR_PANE_ID"),
         socket when is_binary(socket) and socket != "" <- Map.get(env, "HERDR_SOCKET_PATH") do
      {:ok, %{pane_id: pane_id, socket_path: socket}}
    else
      _other -> :disabled
    end
  end

  @doc """
  Returns the command that resumes `session_id` after a Herdr server restart.

  Herdr restores a pane in its previous working directory, which is the
  project the session is stored under. The model and reasoning level are
  omitted on purpose: an unmodified resume adopts the session's recorded
  selection, including changes made during the session. `--abandon` is
  omitted too: a turn cut off by the restart needs the operator's recovery
  decision, so the restored pane shows the usual recovery message instead of
  abandoning the turn unseen.
  """
  @spec resume_argv(String.t()) :: [String.t()]
  def resume_argv(session_id) when is_binary(session_id),
    do: ["tackle", "--resume", session_id]

  @doc "Builds a `pane.report_agent` request for `report` with sequence `seq`."
  @spec report_request(config(), report(), pos_integer()) :: request()
  def report_request(%{pane_id: pane_id}, %{state: state} = report, seq)
      when state in [:idle, :working] and is_integer(seq) do
    params =
      %{
        "pane_id" => pane_id,
        "source" => @source,
        "agent" => @agent,
        "state" => Atom.to_string(state),
        "seq" => seq
      }
      |> put_present("agent_session_id", Map.get(report, :session_id))
      |> put_present("resume_argv", Map.get(report, :resume_argv))

    request("pane.report_agent", params, seq)
  end

  @doc """
  Builds a `pane.release_agent` request with sequence `seq`.

  Releasing clears the agent's name, state, and resume command from the pane,
  so it is sent only when the user quits.
  """
  @spec release_request(config(), pos_integer()) :: request()
  def release_request(%{pane_id: pane_id}, seq) when is_integer(seq) do
    request(
      "pane.release_agent",
      %{"pane_id" => pane_id, "source" => @source, "agent" => @agent, "seq" => seq},
      seq
    )
  end

  @doc """
  Returns the next report sequence after `last`.

  Herdr ignores a report whose sequence is not higher than the last one it
  accepted from this source, including reports from an earlier Tackle process,
  so the sequence follows the wall clock in microseconds and only steps past
  `last` when the clock has not advanced.
  """
  @spec next_seq(non_neg_integer()) :: pos_integer()
  def next_seq(last) when is_integer(last), do: max(System.os_time(:microsecond), last + 1)

  @doc """
  Sends one request to Herdr's socket and waits for its reply.

  `timeout` bounds the whole exchange, connecting included. Returns
  `{:error, {:herdr, code, message}}` when Herdr rejects the request and
  `{:error, reason}` for transport failures, including a socket path the
  platform cannot address. Callers are expected to ignore failures: Herdr
  reporting never affects the shell.
  """
  @spec send_request(config(), request(), non_neg_integer()) :: :ok | {:error, term()}
  def send_request(%{socket_path: path}, request, timeout \\ @timeout)
      when is_integer(timeout) and timeout >= 0 do
    deadline = System.monotonic_time(:millisecond) + timeout
    options = [:binary, packet: :line, packet_size: @max_response_bytes, active: false]

    case connect(path, options, timeout) do
      {:ok, socket} ->
        try do
          with :ok <- :gen_tcp.send(socket, [JSON.encode!(request), ?\n]),
               {:ok, line} <- :gen_tcp.recv(socket, 0, remaining(deadline)) do
            decode_reply(line)
          end
        after
          :gen_tcp.close(socket)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `:gen_tcp` exits with `:badarg` instead of returning an error for a local
  # address it cannot represent, such as a path longer than `sun_path`.
  defp connect(path, options, timeout) do
    :gen_tcp.connect({:local, path}, 0, options, timeout)
  catch
    :exit, :badarg -> {:error, :invalid_socket_path}
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp decode_reply(line) do
    case JSON.decode(line) do
      {:ok, %{"error" => %{"code" => code} = error}} ->
        {:error, {:herdr, code, Map.get(error, "message")}}

      {:ok, %{}} ->
        :ok

      {:ok, other} ->
        {:error, {:unexpected_reply, other}}

      {:error, reason} ->
        {:error, {:invalid_reply, reason}}
    end
  end

  defp request(method, params, seq) do
    %{"id" => "#{@source}:#{seq}", "method" => method, "params" => params}
  end

  defp put_present(params, _key, nil), do: params
  defp put_present(params, key, value), do: Map.put(params, key, value)
end
