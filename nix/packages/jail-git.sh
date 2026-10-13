# Git mounts for the exec-jail launcher (exec-jail.nix). Sourced by the
# launcher, which runs on the host before the jail starts; it only appends
# Bubblewrap arguments to RUNTIME_ARGS and creates empty Git files and
# directories on the host.
#
# Git runs hooks and honours core.hooksPath, core.fsmonitor, and other
# settings from its configuration on the host, so jailed code must not be able
# to change what host Git reads as configuration: config, config.worktree,
# hooks, and the worktree metadata under worktrees/. Each is mounted
# read-only, and missing ones are created on the host first so jailed code
# cannot create them. Mount points cannot be renamed or replaced.
#
# This narrows, but does not remove, the risk of running host Git in a jailed
# workspace. The workspace's own Git directory stays writable, so jailed code
# can still plant a commondir there (the next launch refuses it, but host Git
# outside Tackle follows it), plant rebase or cherry-pick state whose `exec`
# lines a host `git rebase --continue` runs, or change the configuration of
# submodules under its modules/. Writable objects and refs let it add object
# alternates and symbolic refs that host Git follows. Nested repositories
# created in the jail are not covered either.
#
# Runs under the launcher's errexit, nounset, and pipefail.

_tackle_git_refuse() {
  echo "tackle-exec-jail: $*" >&2
  exit 2
}

# Prints the start of the first line of a Git pointer file. Bounded, because
# jailed code may have written the file in an earlier, unprotected session.
_tackle_git_first_line() {
  local line=""
  if [[ -f "$1" && ! -L "$1" ]]; then
    IFS= read -r -n 4096 line < "$1" || true
  fi
  printf '%s' "$line"
}

# Resolves a Git pointer: absolute, or relative to `$1`. Fails when the target
# does not exist.
_tackle_git_resolve() {
  local base=$1 target=$2
  [[ -n "$target" ]] || return 1
  [[ "$target" == /* ]] || target="$base/$target"
  realpath -e -- "$target" 2> /dev/null
}

_tackle_git_no_links() {
  local path
  for path in "$@"; do
    if [[ -L "$path" ]]; then
      _tackle_git_refuse "refusing the symbolic link $path in a Git directory"
    fi
  done
}

# Binds the directory `$1` writable through a file descriptor that is checked
# to be that directory, so a symbolic link swapped in after the checks is not
# followed. A running jail of the main checkout can rename entries of its
# .git, such as objects, while a worktree's jail starts.
_tackle_git_bind_dir() {
  local path=$1 fd
  exec {fd}< "$path"
  if [[ "$(readlink "/proc/self/fd/$fd")" != "$path" || ! -d "/proc/self/fd/$fd" ]]; then
    _tackle_git_refuse "$path changed while the jail started"
  fi
  RUNTIME_ARGS+=(--bind-fd "$fd" "$path")
}

# Git follows commondir in any Git directory. A repository's own Git
# directory has none, so one there was planted.
_tackle_git_no_commondir() {
  if [[ -e "$1/commondir" || -L "$1/commondir" ]]; then
    _tackle_git_refuse "unexpected $1/commondir"
  fi
}

# The workspace is a main checkout: mount its .git directory writable, with
# its host-executed settings read-only. Host Git also reads it for every
# linked worktree of the repository, so their metadata under worktrees/ is
# read-only too; worktrees are created on the host.
_tackle_git_main_checkout() {
  local git_dir=$1 entry

  _tackle_git_no_links "$git_dir"/{hooks,config,config.worktree,worktrees}
  _tackle_git_no_commondir "$git_dir"

  mkdir -p "$git_dir/hooks" "$git_dir/worktrees"
  [[ -e "$git_dir/config" ]] || : > "$git_dir/config"
  # Read only with extensions.worktreeConfig, which the read-only config keeps
  # jailed code from enabling, but the host may enable it later.
  [[ -e "$git_dir/config.worktree" ]] || : > "$git_dir/config.worktree"

  RUNTIME_ARGS+=(--bind "$git_dir" "$git_dir")
  for entry in hooks config config.worktree worktrees; do
    RUNTIME_ARGS+=(--ro-bind "$git_dir/$entry" "$git_dir/$entry")
  done
}

# The workspace `$1` is a linked worktree (`git worktree add`, as Herdr
# creates): its .git file names the worktree's Git directory `$3`,
# `<common>/worktrees/<name>`, and the objects and refs live in the common Git
# directory, which is also the main checkout's own .git directory.
#
# The worktree's Git directory is writable apart from its pointers. The common
# directory is readable, and read-only apart from objects, refs, branch
# reflogs, and the rerere cache, so commits, merges, rebases, stashes,
# fetches, and pushes work while the main checkout's HEAD, index,
# configuration, and rebase state cannot be changed. (With the reftable
# backend, the main checkout's HEAD is in the writable reftable directory.)
# Deleting or renaming a ref, writing configuration, and gc need the common
# directory itself and fail in the jail. The working trees of the main
# checkout and other worktrees are not mounted. Both pointers are checked
# before anything is mounted, so a .git file aimed at another repository's
# worktree is refused.
_tackle_git_linked_worktree() {
  local workspace=$1 home=$2 git_dir=$3 common target entry

  common=$(dirname "$(dirname "$git_dir")")
  if [[ "$(basename "$(dirname "$git_dir")")" != worktrees ]]; then
    _tackle_git_refuse "$git_dir is not a linked worktree's Git directory"
  fi

  _tackle_git_no_links "$git_dir"/{commondir,gitdir,config.worktree}
  target=$(_tackle_git_resolve "$git_dir" "$(_tackle_git_first_line "$git_dir/commondir")") || target=""
  if [[ "$target" != "$common" ]]; then
    _tackle_git_refuse "$git_dir/commondir does not name $common"
  fi

  # Git records where the worktree is; a mismatch means a moved worktree
  # (`git worktree repair` fixes it) or a .git file aimed at another one.
  target=$(_tackle_git_resolve "$git_dir" "$(_tackle_git_first_line "$git_dir/gitdir")") || target=""
  if [[ "$target" != "$workspace/.git" ]]; then
    _tackle_git_refuse "$git_dir/gitdir does not name $workspace/.git; run 'git worktree repair' on the host"
  fi

  # The same rule as for the workspace, and the workspace must stay writable.
  if [[ "$common" == / || "$home/" == "$common/"* || "$workspace/" == "$common/"* ]]; then
    _tackle_git_refuse "refusing to mount $common as the common Git directory"
  fi
  _tackle_git_no_commondir "$common"
  _tackle_git_no_links "$common"/{objects,refs,logs,logs/refs,rr-cache,reftable}
  if [[ ! -d "$common/objects" || ! -d "$common/refs" ]]; then
    _tackle_git_refuse "$common is not a Git directory"
  fi

  # Branch reflogs need logs/refs. Create it from inside the resolved logs
  # directory, so a symbolic link swapped in is not followed.
  if [[ ! -d "$common/logs/refs" ]]; then
    if ! (cd "$common" && mkdir -p logs && cd -P logs &&
      [[ "$(pwd -P)" == "$common/logs" ]] && mkdir -p refs); then
      _tackle_git_refuse "cannot create $common/logs/refs"
    fi
  fi
  [[ -e "$git_dir/config.worktree" ]] || : > "$git_dir/config.worktree"

  RUNTIME_ARGS+=(--ro-bind "$common" "$common")
  for entry in objects refs logs/refs rr-cache reftable; do
    if [[ -d "$common/$entry" ]]; then
      _tackle_git_bind_dir "$common/$entry"
    fi
  done
  RUNTIME_ARGS+=(--bind "$git_dir" "$git_dir")
  for entry in commondir gitdir config.worktree; do
    RUNTIME_ARGS+=(--ro-bind "$git_dir/$entry" "$git_dir/$entry")
  done
}

# Appends the Git mounts for the workspace `$1`, the resolved current
# directory, given the resolved home directory `$2`.
tackle_jail_git_mounts() {
  local workspace=$1 home=$2 dot_git=$1/.git line git_dir

  if [[ -L "$dot_git" ]]; then
    _tackle_git_refuse "refusing the symbolic link $dot_git"
  elif [[ -d "$dot_git" ]]; then
    _tackle_git_main_checkout "$dot_git"
  elif [[ -f "$dot_git" ]]; then
    # The .git file itself is read-only, so jailed code cannot repoint it.
    RUNTIME_ARGS+=(--ro-bind "$dot_git" "$dot_git")

    line=$(_tackle_git_first_line "$dot_git")
    if [[ "$line" == "gitdir: "* ]] &&
      git_dir=$(_tackle_git_resolve "$workspace" "${line#gitdir: }") &&
      [[ -e "$git_dir/commondir" || -L "$git_dir/commondir" ]]; then
      _tackle_git_linked_worktree "$workspace" "$home" "$git_dir"
    fi
    # Otherwise a submodule or something else: its Git directory stays
    # outside the jail, and Git does not work in it.
  elif [[ -e "$dot_git" ]]; then
    _tackle_git_refuse "$dot_git is neither a directory nor a file"
  fi
}
