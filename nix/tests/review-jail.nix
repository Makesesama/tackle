{
  pkgs,
  mkReviewJail,
  productionJail,
}:
# Host smoke test, not a sandboxed build: Bubblewrap needs user namespaces.
# nix build .#tackle-review-jail.tests.smoke
# ./result/bin/test-tackle-review-jail
let
  inherit (pkgs) lib;
  tackleExec = pkgs.callPackage ../packages/tackle-exec.nix { };
  executor = ../../packages/tackle_tools/lib/tackle/executor.ex;
  jailed = ../../packages/tackle_tools/lib/tackle/executor/jailed.ex;
  reviewJail = ../../apps/tackle_web/lib/tackle_web/review_jail.ex;
  unrelated = pkgs.writeText "review-jail-host-only" "not in the tool closure";
  driver = pkgs.writeText "review-jail-smoke.exs" ''
    [launcher, state, tree, clone, unrelated] = System.argv()
    Application.put_env(:tackle_web, :review_jail, launcher)
    alias Tackle.Web.ReviewJail
    alias Tackle.Executor
    checkout = %{worktree: tree, clone: clone, state_dir: state}
    {:ok, handle} = ReviewJail.start(checkout)
    try do
      script = """
      set -eu
      test "$GIT_OPTIONAL_LOCKS" = 0
      test -z "''${TACKLE_REVIEW_SMOKE_SECRET:-}"
      test ! -e "$1"
      test ! -e /nix/var/nix/daemon-socket/socket
      test ! -e /nix/var/nix/db/db.sqlite
      test ! -e "$2/credentials"
      test ! -e "$HOME/.config/ketch/config.json"
      test ! -e /run/postgresql
      test ! -e /var/lib/postgresql
      # Resource limits (review-jail.nix): the kernel prefers the jail when
      # memory runs out, files and private tmpfs mounts are bounded, and
      # jailed code cannot raise the file size limit.
      test "$(cat /proc/self/oom_score_adj)" = 1000
      test "$(ulimit -f)" = 262144
      test "$(ulimit -H -f)" = 262144
      if (ulimit -f unlimited) 2>/dev/null; then exit 1; fi
      for dir in /tmp "$HOME" /dev/shm; do
        test "$(df -B1 --output=size "$dir" | tail -n 1 | tr -d ' ')" = 268435456
      done
      git status --short >/dev/null
      test -n "$(git rev-parse HEAD)"
      gitdir=$(git rev-parse --absolute-git-dir)
      for dir in "$PWD" "$3" "$3/objects" "$3/refs" "$gitdir"; do
        if touch "$dir/planted" 2>/dev/null; then exit 1; fi
      done
      if printf x 2>/dev/null >> .git; then exit 1; fi
      if printf x 2>/dev/null >> "$3/HEAD"; then exit 1; fi
      if printf x 2>/dev/null >> "$gitdir/commondir"; then exit 1; fi
      touch /tmp/private-scratch
      """
      {:ok, ref} = Executor.exec(handle.executor,
        ["bash", "-c", script, "probe", unrelated, state, clone], cwd: tree)
      await = fn await ->
        case Executor.await(handle.executor, ref, 10_000) do
          {:data, data} -> IO.write(data); await.(await)
          {:exit_status, 0} -> :ok
          other -> raise "review launcher smoke failed: #{inspect(other)}"
        end
      end
      await.(await)
    after
      :ok = ReviewJail.stop(handle)
    end
    IO.puts("Review jail protocol and isolation: OK")
  '';
  # A tiny replacement entry permits pointer-refusal tests without speaking
  # the protocol. It has exactly the production launcher's mount policy.
  probe = pkgs.writeShellApplication {
    name = "review-jail-pointer-probe";
    text = ''
      if touch .tackle-must-not-write 2>/dev/null; then exit 1; fi
      if [[ -d .git ]] && touch .git/must-not-write 2>/dev/null; then exit 1; fi
    '';
  };
  pointerJail = mkReviewJail {
    name = "review-jail-pointer-test";
    entry = probe;
  };
in
pkgs.writeShellApplication {
  name = "test-tackle-review-jail";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.diffutils
    pkgs.findutils
    pkgs.git
    pkgs.gnugrep
    pkgs.beamPackages.elixir
  ];
  text = ''
    # /tmp and HOME are private inside the jail. Keep test state elsewhere.
    work=$(mktemp -d -p "$(pwd -P)" .tackle-review-jail-smoke.XXXXXX)
    trap 'if [ "$?" -eq 0 ]; then rm -rf "$work"; else echo "kept $work" >&2; fi' EXIT
    export HOME="$work/home"
    export TACKLE_REVIEW_SMOKE_SECRET=host-only
    mkdir -p "$HOME/.config/ketch" "$work/state"
    printf 'host-only\n' > "$HOME/.config/ketch/config.json"
    printf 'host-only\n' > "$work/state/credentials"
    clone="$work/state/clone"
    tree="$work/state/tree"
    git init --quiet --bare "$clone"
    git --git-dir="$clone" -c user.name=host -c user.email=host@localhost \
      commit-tree "$(git --git-dir="$clone" mktree < /dev/null)" -m init > "$work/head"
    git --git-dir="$clone" update-ref refs/heads/main "$(cat "$work/head")"
    git --git-dir="$clone" worktree add --quiet --detach "$tree" main

    snapshot() {
      find "$clone" "$tree" -printf '%p %y %m\n' | sort
      find "$clone" "$tree" -type f -exec sha256sum {} + | sort
    }
    snapshot > "$work/before"
    elixir -pa ${tackleExec}/lib/erlang/lib/tackle_exec-0.1.0/ebin \
      -r ${executor} -r ${jailed} -r ${reviewJail} ${driver} \
      ${lib.getExe productionJail} "$work/state" "$tree" "$clone" ${unrelated}
    snapshot > "$work/after"
    cmp "$work/before" "$work/after"
    test ! -e "$clone/logs/refs"
    test ! -e "$clone/worktrees/tree/config.worktree"

    # The reusable read-only option also handles a main checkout without
    # creating the absent configuration, hooks, or worktree metadata.
    main="$work/main"
    git init --quiet "$main"
    rm -rf "$main/.git/hooks"
    (cd "$main" && ${lib.getExe pointerJail} "$work/main.log")
    test ! -e "$main/.git/hooks"
    test ! -e "$main/.git/config.worktree"
    test ! -e "$main/.git/worktrees"

    refused() {
      local dir=$1 message=$2
      : > "$work/refusal.log"
      if (cd "$dir" && ${lib.getExe pointerJail} "$work/refusal.log"); then exit 1; fi
      grep -qF "$message" "$work/refusal.log"
    }
    mkdir "$work/state/crafted"
    cp "$tree/.git" "$work/state/crafted/.git"
    refused "$work/state/crafted" 'does not name'
    touch "$clone/commondir"
    refused "$tree" 'unexpected'
    rm "$clone/commondir"
    mv "$clone/objects" "$clone/objects-real"
    ln -s objects-real "$clone/objects"
    refused "$tree" 'symbolic link'
    rm "$clone/objects"
    mv "$clone/objects-real" "$clone/objects"
    mv "$tree/.git" "$tree/git-pointer"
    ln -s git-pointer "$tree/.git"
    refused "$tree" 'symbolic link'
    printf 'Read-only Git pointer validation: OK\n'
  '';
}
