# gix_ex

Read-only Git access for Elixir, backed by Rust's
[gitoxide](https://github.com/GitoxideLabs/gitoxide) (`gix`) through a Rustler
NIF. It resolves revisions, finds merge bases, walks history, and computes
diffs in-process, without a `git` executable, and returns diffs as data
instead of patch text.

Status: experimental. It is meant to load changes for `tackle review` in
place of `git diff` subprocesses, but nothing in the harness or the CLI uses it
yet, and it is not wired into the Nix build.

```elixir
{:ok, repo} = GixEx.open(".")
{:ok, base} = GixEx.merge_base(repo, "main", "HEAD")

# Everything the branch changes, committed or not, as `git diff BASE` shows it.
{:ok, files} = GixEx.diff(repo, base, :worktree, contents: true)

for %GixEx.Diff.File{path: path, status: status, hunks: hunks} <- files,
    %GixEx.Diff.Hunk{lines: lines} <- hunks,
    %{kind: :add, new: line, text: text} <- lines do
  IO.puts("#{status} #{path}:#{line} #{text}")
end

{:ok, commits} = GixEx.commits(repo, base, "HEAD", limit: 100)
```

## API

| Function | Git equivalent |
| --- | --- |
| `open/1` | repository discovery; `workdir` is `rev-parse --show-toplevel` |
| `resolve/2` | `rev-parse --verify REV^{commit}` |
| `merge_base/3` | `merge-base A B` |
| `symbolic_ref/3` | `symbolic-ref [--short] NAME` |
| `empty_tree/1` | the empty tree id |
| `commits/4` | `log BASE..HEAD`, with `%s` and `%b` |
| `diff/4` | `diff FROM TO`, `diff --cached FROM`, `diff FROM` |

`diff/4` compares a revision or the empty tree with a revision, the empty
tree, the index (`:index`), or the tracked files of the working tree
(`:worktree`). Every file carries its status, paths, modes, counts, and hunks;
every hunk line carries its kind and absolute old and new line numbers. With
`contents: true`, each file also carries the full text of both sides, which is
what a caller needs to find enclosing functions itself.

## Fidelity

The tests compare GixEx with the `git` executable. With the default
`:histogram` algorithm, hunks are byte-for-byte what
`git diff --histogram` prints: ranges, context merging, `\ No newline at end
of file`, and section headings. Known differences:

- Rename similarity is scored differently, so a pair close to the threshold
  (50% by default) can be a rename in one and a deletion plus an addition in
  the other. Copies are not detected.
- `algorithm: :myers` is not Git's Myers implementation; it aligns about 1% of
  changed files differently.
- Section headings use Git's default rule (a line starting with a letter,
  `_`, or `$`), not language rules set with `diff=<driver>` attributes.
- Working-tree files are compared as stored: no clean filters and no
  end-of-line conversion. A submodule is compared by the commit recorded in
  the index, not by its checkout.
- `.gitattributes` are read from the index, not from the working tree. Only
  the `diff` attribute is used: `-diff`, `binary`, and drivers with
  `diff.<driver>.binary` make a file binary, and `diff` makes it text.

As in Git, unmerged paths are reported as `:unmerged` against the index and
with their conflict markers against the working tree, and assume-unchanged and
skip-worktree entries are taken from the index.

## Untrusted repositories

`tackle review` runs on checkouts an agent may have written to, so the
bindings assume the repository can be hostile:

- Repositories are opened isolated: only the repository's own configuration is
  read. No call runs a program the repository configures (filters,
  `textconv`, external diff drivers, hooks).
- Reads stay inside the working tree. A repository whose working tree is
  configured elsewhere (`core.worktree`) is refused with `:external_worktree`;
  a tracked path below a symbolic link counts as deleted, as in Git; index
  paths with `..`, `.`, or `.git` components are rejected; searching upwards
  only recognises `.git` directories, so a bare repository committed inside a
  checkout is not picked up.
- Only regular files and symbolic links are read, opened without following
  links or blocking; a FIFO or device in place of a tracked file counts as
  deleted. A file over `:max_file_bytes` is hashed as a stream and reported as
  binary, so no single file is held in memory beyond that limit.

Calls run on dirty I/O schedulers and cannot be interrupted or given a
timeout.

## Development

The crate builds with Cargo through Rustler on `mix compile`.

```sh
mix deps.get
mix compile --warnings-as-errors
mix test
mix format --check-formatted
(cd native/gix_ex && cargo fmt --check && cargo clippy --all-targets && cargo test)

# Opt-in: compare with `git diff --histogram` on this repository's history.
# GIX_EX_HISTORY_COMMITS (default 200) and GIX_EX_HISTORY_RENAMES=1.
mix test --only history
```

The tests need `git` to build fixture repositories and as the reference
implementation.
