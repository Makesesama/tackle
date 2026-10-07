{
  pkgs,
  beamPackages ? pkgs.beamPackages,
}:

# The jailed half of Tackle: Erlang, Elixir's standard library, and
# tackle_exec. It speaks the exec-server protocol on standard input and output.
let
  tackleExec = pkgs.callPackage ./tackle-exec.nix { inherit beamPackages; };
in
pkgs.writeShellApplication {
  name = "tackle-exec-server";
  text = ''
    exec ${beamPackages.erlang}/bin/erl -noshell -noinput \
      -pa ${beamPackages.elixir}/lib/elixir/lib/elixir/ebin \
      -pa ${tackleExec}/lib/erlang/lib/tackle_exec-0.1.0/ebin \
      -s Elixir.Tackle.Exec.Server main
  '';
}
