defmodule Tackle.Hub.Checkout.Git do
  @moduledoc false

  # The guardian retains the flock until its whole Git process group is stopped.
  # A replacement global-lock owner first takes this OS lock too, so owner death
  # cannot race stale-lock/staging recovery with the old credentialed fetch.
  @guardian """
  timeout=$1; lock=$2; shift 2
  exec 3<&0
  child= locker= watcher=
  cleanup() {
    trap '' TERM
    if [[ -n "$child" ]]; then
      if kill -TERM -- -"$child" 2>/dev/null || kill -TERM "$child" 2>/dev/null; then
        sleep 0.2
        kill -KILL -- -"$child" 2>/dev/null || kill -KILL "$child" 2>/dev/null
      fi
    fi
    [[ -z "$locker" ]] || kill "$locker" 2>/dev/null
    [[ -z "$watcher" ]] || kill "$watcher" 2>/dev/null
    wait 2>/dev/null
  }
  trap cleanup EXIT
  (read -r -t "$timeout" _ <&3; exit 124) & watcher=$!
  if [[ -n "$lock" ]]; then
    exec 9>"$lock" || exit 1
    flock -x 9 3<&- & locker=$!
    wait -n -p finished "$locker" "$watcher"
    status=$?
    [[ "$finished" == "$locker" && "$status" == 0 ]] || exit "$status"
    locker=
  fi
  "$@" </dev/null 2>/dev/null 3<&- & child=$!
  wait -n "$child" "$watcher"
  exit $?
  """

  @doc false
  def sync(opts) do
    run(["--version"], [], Map.put(opts, :git, System.find_executable("git")))
  end

  @spec run([String.t()], [{String.t(), String.t()}], map()) :: :ok | {:error, atom()}
  def run(args, auth_env, opts) do
    bash = System.find_executable("bash")
    setsid = System.find_executable("setsid")
    git = Map.get(opts, :git, System.find_executable("git"))

    if bash && setsid && git && System.find_executable("flock") do
      execute(
        bash,
        setsid,
        git,
        args,
        auth_env,
        Map.get(opts, :timeout, 120_000),
        Map.get(opts, :expected_output),
        Map.get(opts, :lock_path, "")
      )
    else
      {:error, :git_unavailable}
    end
  rescue
    _error -> {:error, :git_failed}
  end

  defp execute(bash, setsid, git, args, auth_env, timeout, expected, lock_path) do
    env =
      Enum.map(System.get_env(), fn {key, _value} -> {key, nil} end) ++
        [
          {"PATH", System.get_env("PATH", "/usr/bin:/bin")},
          {"HOME", "/nonexistent"},
          {"LANG", "C"},
          {"GIT_CONFIG_NOSYSTEM", "1"},
          {"GIT_CONFIG_GLOBAL", "/dev/null"},
          {"GIT_TERMINAL_PROMPT", "0"}
        ] ++ ca_env() ++ auth_env

    argv =
      [
        "--noprofile",
        "--norc",
        "-c",
        @guardian,
        "checkout-git",
        to_string(timeout / 1000),
        lock_path,
        setsid,
        git,
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "protocol.file.allow=never",
        "-c",
        "credential.helper=",
        "-c",
        "http.followRedirects=false"
      ] ++ args

    port =
      Port.open({:spawn_executable, bash}, [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        args: argv,
        env:
          Enum.map(env, fn {key, value} ->
            {String.to_charlist(key), if(value, do: String.to_charlist(value), else: false)}
          end)
      ])

    try do
      await(port, expected, "", System.monotonic_time(:millisecond) + timeout + 5_000)
    after
      close(port)
    end
  end

  # Do not inherit caller-controlled TLS bypasses or CA overrides. NixOS and
  # conventional Linux hosts expose system trust here even with Git config off.
  defp ca_env do
    path = "/etc/ssl/certs/ca-certificates.crt"
    if File.regular?(path), do: [{"GIT_SSL_CAINFO", path}], else: []
  end

  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp await(port, expected, output, deadline) do
    receive do
      {^port, {:data, data}} ->
        # Keep only enough for the fixed SHA check, never expose Git output.
        output =
          if expected,
            do: binary_part(output <> data, 0, min(byte_size(output <> data), 256)),
            else: ""

        await(port, expected, output, deadline)

      {^port, {:exit_status, 0}} ->
        if is_nil(expected) or output == expected, do: :ok, else: {:error, :git_failed}

      {^port, {:exit_status, 124}} ->
        {:error, :git_timeout}

      {^port, {:exit_status, _status}} ->
        {:error, :git_failed}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        close(port)
        {:error, :git_timeout}
    end
  end
end
