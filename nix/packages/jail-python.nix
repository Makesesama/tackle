{ pkgs }:

# Python for the agent's scripts, with the libraries it reaches for most and
# `pip` for the rest. `pkgs.python3` is the full interpreter (ssl, sqlite3,
# zlib, ctypes, readline), not `python3Minimal`, which lacks those modules.
#
# This is a jail tool, so it belongs with the launchers that put it on the
# agent's PATH (jailed-tackle-cli.nix, jailed-tackle.nix) rather than with the
# CLI's own dependencies: the harness never runs Python.
#
# Note that `pip install <pkg>` cannot write into the store. The two working
# patterns are a virtualenv in the workspace, which persists, or
# `pip install --user`, which the jail's private home holds for the lifetime
# of the CLI process. `nix shell nixpkgs#python3Packages.<pkg>` also works in
# the production jail, which mounts the store and the Nix daemon.
pkgs.python3.withPackages (
  ps: with ps; [
    pip
    requests
    pyyaml
    beautifulsoup4
  ]
)
