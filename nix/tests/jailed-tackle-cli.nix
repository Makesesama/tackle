{
  pkgs,
  mkExecJail,
  execJail,
  productionJail,
}:

# Credential-free host smoke test for the production jail. Run it on a Linux
# host, not in a Nix build sandbox: Bubblewrap needs user namespaces, and the
# Nix check intentionally uses the host daemon.
#
#   nix build .#tackle-cli-jail.tests.smoke && ./result/bin/test-jailed-tackle-cli
let
  inherit (pkgs) lib;
  beamPackages = pkgs.beamPackages;
  tackleExec = pkgs.callPackage ../packages/tackle-exec.nix { inherit beamPackages; };

  # Runs inside the jail, with the same policy as the exec-server, in place of
  # it. Its arguments are the host paths it must not see.
  probe = pkgs.writeShellApplication {
    name = "tackle-jail-probe";
    text = ''
      host_home=$1
      test ! -e "$host_home/host-only"
      test ! -e "$host_home/.tackle/auth.json"
      test ! -e "$HOME/host-only"
      test -z "''${TACKLE_SMOKE_SECRET:-}"
      test "$LANG" = C.UTF-8

      # The workspace is writable, except Git's host-executed settings.
      touch written-in-jail
      git status --short > /dev/null
      if touch .git/hooks/pre-commit 2> /dev/null; then exit 1; fi
      # Redirect stderr before the failing write: bash reports a failed
      # redirection to the still-original stderr, which would leak a
      # confusing "Read-only file system" line into the jail log.
      if printf '[core]\n' 2> /dev/null >> .git/config; then exit 1; fi
      if mv .git .git-moved 2> /dev/null; then exit 1; fi

      ketch --help > /dev/null
      test "$(cat "$HOME/.config/ketch/config.json")" = '{}'

      test "$NIX_REMOTE" = daemon
      test -S /nix/var/nix/daemon-socket/socket
      # No network, credentials, nixpkgs fetch, or model call. A unique name
      # forces a new output, checking visibility after the jail has started.
      # The builder path reaches the expression as plain text, so it carries no
      # derivation context: without storePath a sandboxed daemon (the NixOS
      # default) does not mount it into the build sandbox. --impure only allows
      # that builtin; --offline still forbids substituters.
      # shellcheck disable=SC2016
      output=$(nix build --impure --offline --no-link --print-out-paths --expr '
        let bash = builtins.storePath "${pkgs.bash}"; in
        derivation {
          name = "tackle-jail-smoke-'"$(date +%s%N)"'";
          system = "${pkgs.stdenv.hostPlatform.system}";
          builder = "''${bash}/bin/bash";
          args = [ "-c" "echo built-inside-jail > $out" ];
        }
      ')
      test "$(cat "$output")" = built-inside-jail
      printf 'Jail policy: OK\n'
    '';
  };
  probeJail = mkExecJail {
    name = "tackle-jail-probe";
    entry = probe;
  };

  # Drives the real exec-server through the protocol client, as the CLI does.
  client = pkgs.writeText "tackle-exec-smoke.exs" ''
    [launcher, log, host_home] = System.argv()
    cwd = File.cwd!()
    alias Tackle.Exec.Client

    {:ok, client} =
      Client.start_link(launcher: {launcher, [log]}, keep_env: ["PATH", "HOME", "LANG"])

    {:ok, %{type: :directory}} = Client.stat(client, cwd)
    {:error, :enoent} = Client.stat(client, Path.join(host_home, ".tackle/auth.json"))

    {:ok, ref} = Client.exec(client, ["sh", "-c", "echo jailed > out.txt; cat out.txt"], cwd: cwd)

    receive do
      {:tackle_exec, ^ref, {:data, "jailed\n"}} -> Client.ack(client, ref, 7)
    after
      10_000 -> raise "no command output"
    end

    receive do
      {:tackle_exec, ^ref, {:exit_status, 0}} -> :ok
    after
      10_000 -> raise "no exit status"
    end

    "jailed\n" = File.read!(Path.join(cwd, "out.txt"))
    IO.puts("Exec-server protocol: OK")
  '';
in
pkgs.writeShellApplication {
  name = "test-jailed-tackle-cli";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.git
    beamPackages.elixir
  ];
  text = ''
    # Not under /tmp: the jail replaces /tmp anyway, which would hide a leak.
    work=$(mktemp -d -p "$PWD" .tackle-jail-smoke.XXXXXX)
    # The jail redirects its stderr to the log file inside $work, so a
    # failure would otherwise be silent. Keep the work dir for diagnosis.
    trap 'if [ "$?" -eq 0 ]; then rm -rf "$work"; else echo "smoke test failed; kept $work (exec-server log: $work/exec-server.log)" >&2; fi' EXIT
    mkdir -p "$work/home/.config/ketch" "$work/home/.tackle" "$work/project"
    export HOME="$work/home"
    touch "$HOME/host-only"
    printf '{"secret": true}\n' > "$HOME/.tackle/auth.json"
    printf '{}\n' > "$HOME/.config/ketch/config.json"
    export TACKLE_SMOKE_SECRET=leaked
    export LANG=C.UTF-8
    export TERM="''${TERM:-xterm}"

    cd "$work/project"
    git init --quiet
    log="$work/exec-server.log"

    ${lib.getExe probeJail} "$log" "$HOME"
    test -e written-in-jail
    test -f .git/config

    # A Git common directory planted in an earlier session blocks the launch.
    touch .git/commondir
    if ${lib.getExe probeJail} "$log" "$HOME"; then exit 1; fi
    rm .git/commondir
    printf 'Planted .git/commondir refused: OK\n'

    elixir -pa ${tackleExec}/lib/erlang/lib/tackle_exec-0.1.0/ebin \
      ${client} ${lib.getExe execJail} "$log" "$HOME"

    # The production CLI boots Tackle.Auth.Store on the host, which validates
    # the auth file. The canary is deliberately invalid (it only exists to
    # prove the jail cannot see it), so point the CLI at an empty Tackle home:
    # a missing auth file is the normal credential-free state. Keep Burrito
    # extraction out of the user's real ~/.tackle as well.
    mkdir -p "$work/tackle-home" "$work/burrito"
    TACKLE_HOME="$work/tackle-home" TACKLE_CLI_INSTALL_DIR="$work/burrito" \
      ${lib.getExe productionJail} --version
    TACKLE_HOME="$work/tackle-home" TACKLE_CLI_INSTALL_DIR="$work/burrito" \
      ${lib.getExe productionJail} --help > /dev/null
    printf 'Production jailed CLI: OK\n'
  '';
}
