defmodule Tackle.Bench.ReviewEval.Case do
  @moduledoc """
  A benchmark case: a past commit of a repository, optionally with bugs
  seeded into it, and the issues a review of it should report.

  A case is one JSON file:

      {
        "id": "seed-off-by-one",
        "description": "Seeds an off-by-one into the unit packer",
        "commit": "<sha>",
        "base": "<sha>",
        "edits": [{"path": "lib/a.ex", "find": "count + 1", "replace": "count"}],
        "issues": [
          {"id": "off-by-one", "path": "lib/a.ex", "anchor": "count)",
           "lines": 1, "keywords": ["boundary"], "description": "...",
           "also": [{"path": "lib/b.ex", "anchor": "A.count(", "lines": 1}]}
        ]
      }

  `id` is a slug (lowercase letters, digits, `.`, `_`, `-`). `commit` is
  checked out in a scratch clone (see `prepare/3`); `base` (default
  `<commit>~1`) is the base of the reviewed range. `edits` (default none)
  are exact, unique string replacements applied to the checked-out files
  and folded into `commit` itself (amended, keeping its message), so the
  reviewed range looks like the original commit with the bug in it. Without
  edits the case is historical: the range is `base..commit`.

  Each issue is located in the reviewed head by its `anchor`, an exact
  substring that occurs exactly once in the file (it may span lines): the
  issue covers the line the anchor starts on and the `lines - 1` following
  ones (default `lines: 1`) on the new side. `also` lists other places a
  correct finding may point at instead, such as the call site that crashes.
  `keywords` (default none) further constrain matching, see
  `Tackle.Bench.ReviewEval.Score`; keep them few and generic, since a
  correct finding may be worded differently.

  Nothing in a checkout may tell the reviewing agents what was seeded or
  how it was fixed later: the checkout directory has an opaque name, the
  seed is not a commit of its own, and the clone keeps no refs (branches,
  tags, remotes, reflogs) that would lead to later commits.
  """

  @enforce_keys [:id, :commit, :issues]
  defstruct [:id, :commit, :issues, :source, description: nil, base: nil, edits: []]

  @type edit :: %{path: String.t(), find: String.t(), replace: String.t()}

  @type place :: %{path: String.t(), anchor: String.t(), lines: pos_integer()}

  @type issue :: %{
          id: String.t(),
          path: String.t(),
          anchor: String.t(),
          lines: pos_integer(),
          also: [place()],
          keywords: [String.t()],
          description: String.t() | nil
        }

  @type t :: %__MODULE__{
          id: String.t(),
          description: String.t() | nil,
          commit: String.t(),
          base: String.t() | nil,
          edits: [edit()],
          issues: [issue(), ...],
          source: Path.t() | nil
        }

  @typedoc "Lines of the reviewed head, on the new side."
  @type location :: %{path: String.t(), start_line: pos_integer(), end_line: pos_integer()}

  @typedoc "An issue located in the reviewed head: its main place first, then the `also` ones."
  @type located_issue :: %{
          id: String.t(),
          locations: [location(), ...],
          keywords: [String.t()],
          description: String.t() | nil
        }

  @typedoc "A case checked out in its own working tree (`worktree`), ready to review."
  @type prepared :: %{
          case: t(),
          worktree: Path.t(),
          base_sha: String.t(),
          head_sha: String.t(),
          range: String.t(),
          issues: [located_issue()]
        }

  @id_format ~r/\A[a-z0-9][a-z0-9._-]*\z/
  # Marks a checkout made by `prepare/3`, so only those are ever deleted.
  @marker "tackle-review-eval"

  @git_identity [
    "-c",
    "user.name=tackle-review-eval",
    "-c",
    "user.email=review-eval@tackle.invalid",
    "-c",
    "commit.gpgsign=false"
  ]

  @doc """
  Loads every `*.json` case in `dir`, sorted by id. Fails on the first
  invalid case, or when two cases share an id.
  """
  @spec load_dir(Path.t()) :: {:ok, [t()]} | {:error, term()}
  def load_dir(dir) do
    dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, cases} ->
      case load_file(path) do
        {:ok, kase} -> {:cont, {:ok, [kase | cases]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, {:no_cases, dir}}
      {:ok, cases} -> unique_ids(Enum.sort_by(cases, & &1.id))
      error -> error
    end
  end

  defp unique_ids(cases) do
    case cases |> Enum.frequencies_by(& &1.id) |> Enum.filter(fn {_id, n} -> n > 1 end) do
      [] -> {:ok, cases}
      [{id, _n} | _] -> {:error, {:duplicate_case, id}}
    end
  end

  @doc "Loads one case file."
  @spec load_file(Path.t()) :: {:ok, t()} | {:error, term()}
  def load_file(path) do
    with {:ok, text} <- File.read(path),
         {:ok, data} <- decode(text, path),
         {:ok, kase} <- parse(data) do
      {:ok, %{kase | source: path}}
    else
      {:error, {:invalid_case, _source, _message} = reason} -> {:error, reason}
      {:error, {:invalid_case, message}} -> {:error, {:invalid_case, path, message}}
      {:error, reason} -> {:error, {:unreadable_case, path, reason}}
    end
  end

  defp decode(text, path) do
    case JSON.decode(text) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:invalid_case, path, "invalid JSON: #{inspect(reason)}"}}
    end
  end

  @doc "Builds a case from decoded JSON (see the module documentation)."
  @spec parse(term()) :: {:ok, t()} | {:error, {:invalid_case, String.t()}}
  def parse(%{} = data) do
    with {:ok, id} <- string(data, "id"),
         :ok <- slug(id),
         {:ok, commit} <- string(data, "commit"),
         {:ok, base} <- optional_string(data, "base"),
         {:ok, description} <- optional_string(data, "description"),
         {:ok, edits} <- list(data, "edits", [], &edit/1),
         {:ok, issues} <- list(data, "issues", nil, &issue/1),
         :ok <- non_empty(issues, "issues") do
      {:ok,
       %__MODULE__{
         id: id,
         description: description,
         commit: commit,
         base: base,
         edits: edits,
         issues: issues
       }}
    end
  end

  def parse(_data), do: invalid("a case must be a JSON object")

  defp slug(id) do
    if Regex.match?(@id_format, id),
      do: :ok,
      else: invalid("id must be lowercase letters, digits, '.', '_', or '-'")
  end

  defp edit(%{} = data) do
    with {:ok, path} <- string(data, "path"),
         {:ok, find} <- string(data, "find"),
         {:ok, replace} <- field(data, "replace", &is_binary/1, "a string") do
      {:ok, %{path: path, find: find, replace: replace}}
    end
  end

  defp edit(_data), do: invalid("every edit must be an object")

  defp issue(%{} = data) do
    with {:ok, id} <- string(data, "id"),
         {:ok, place} <- place(data),
         {:ok, also} <- list(data, "also", [], &place/1),
         {:ok, keywords} <- optional(data, "keywords", [], &string_list?/1, "a list of strings"),
         {:ok, description} <- optional_string(data, "description") do
      {:ok,
       Map.merge(place, %{
         id: id,
         also: also,
         keywords: Enum.map(keywords, &String.downcase/1),
         description: description
       })}
    end
  end

  defp issue(_data), do: invalid("every issue must be an object")

  defp place(%{} = data) do
    with {:ok, path} <- string(data, "path"),
         {:ok, anchor} <- string(data, "anchor"),
         {:ok, lines} <-
           optional(data, "lines", 1, &(is_integer(&1) and &1 > 0), "a positive integer") do
      {:ok, %{path: path, anchor: anchor, lines: lines}}
    end
  end

  defp place(_data), do: invalid("every place in also must be an object")

  defp string(data, key),
    do: field(data, key, &(is_binary(&1) and &1 != ""), "a non-empty string")

  defp optional_string(data, key),
    do: optional(data, key, nil, &(is_binary(&1) and &1 != ""), "a non-empty string")

  defp field(data, key, valid?, expected) do
    case Map.fetch(data, key) do
      {:ok, value} -> check(key, value, valid?, expected)
      :error -> invalid("#{key} is missing")
    end
  end

  defp optional(data, key, default, valid?, expected) do
    case Map.fetch(data, key) do
      {:ok, nil} -> {:ok, default}
      {:ok, value} -> check(key, value, valid?, expected)
      :error -> {:ok, default}
    end
  end

  defp check(key, value, valid?, expected) do
    if valid?.(value), do: {:ok, value}, else: invalid("#{key} must be #{expected}")
  end

  defp list(data, key, default, parse) do
    case Map.get(data, key, default) do
      nil ->
        invalid("#{key} is missing")

      items when is_list(items) ->
        items
        |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
          case parse.(item) do
            {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
          error -> error
        end

      _other ->
        invalid("#{key} must be a list")
    end
  end

  defp non_empty([], key), do: invalid("#{key} must not be empty")
  defp non_empty(_items, _key), do: :ok

  defp string_list?(value), do: is_list(value) and Enum.all?(value, &is_binary/1)

  defp invalid(message), do: {:error, {:invalid_case, message}}

  ## Preparing

  @doc """
  The directory name of a case's checkout: opaque, so the working directory
  the agents are told about does not name the seeded bug.
  """
  @spec checkout_name(t()) :: String.t()
  def checkout_name(%__MODULE__{id: id}) do
    "case-" <> (:crypto.hash(:sha256, id) |> Base.encode16(case: :lower) |> binary_part(0, 10))
  end

  @doc """
  Checks the case out under `workdir` and locates its issues in the
  reviewed head.

  The checkout is a clone sharing the repository's objects
  (`git clone --shared`, so nothing is written to the repository itself),
  at `commit` with the case's edits amended into it. Every ref but the
  detached `HEAD` is deleted, so `git log --all` in the checkout cannot
  lead to the commits that came later, such as a bug's fix.

  A leftover checkout of the same case is replaced; any other directory in
  its place is an error. `repo` is any directory of the repository the
  case's commits belong to.
  """
  @spec prepare(t(), Path.t(), Path.t()) :: {:ok, prepared()} | {:error, term()}
  def prepare(%__MODULE__{} = kase, repo, workdir) do
    worktree = Path.join(Path.expand(workdir), checkout_name(kase))

    with :ok <- remove_checkout(worktree),
         {:ok, toplevel} <- git(repo, ["rev-parse", "--show-toplevel"]),
         {:ok, base_sha} <- rev_parse(repo, kase.base || kase.commit <> "~1"),
         {:ok, commit_sha} <- rev_parse(repo, kase.commit <> "^{commit}") do
      clone = [
        "clone",
        "--quiet",
        "--shared",
        "--no-checkout",
        String.trim(toplevel),
        worktree
      ]

      with :ok <- File.mkdir_p(Path.dirname(worktree)),
           {:ok, _out} <- git(repo, clone),
           :ok <- File.write(Path.join([worktree, ".git", @marker]), kase.id),
           {:ok, _out} <- git(worktree, ["checkout", "--quiet", "--detach", commit_sha]),
           :ok <- strip_refs(worktree),
           :ok <- apply_edits(kase, worktree),
           :ok <- amend_edits(kase, worktree),
           {:ok, head_sha} <- rev_parse(worktree, "HEAD"),
           {:ok, issues} <- locate_issues(kase, worktree) do
        {:ok,
         %{
           case: kase,
           worktree: worktree,
           base_sha: base_sha,
           head_sha: head_sha,
           range: "#{base_sha}..#{head_sha}",
           issues: issues
         }}
      else
        {:error, reason} ->
          _ = remove_checkout(worktree)
          {:error, {:prepare_failed, kase.id, reason}}
      end
    else
      {:error, reason} -> {:error, {:prepare_failed, kase.id, reason}}
    end
  end

  @doc """
  Restores a prepared checkout to its reviewed head, undoing anything a
  previous run changed in it.
  """
  @spec reset(prepared()) :: :ok | {:error, term()}
  def reset(%{worktree: worktree, head_sha: head_sha}) do
    with {:ok, _out} <- git(worktree, ["reset", "--quiet", "--hard", head_sha]),
         {:ok, _out} <- git(worktree, ["clean", "--quiet", "-d", "--force", "-x"]) do
      :ok
    end
  end

  @doc "Removes a prepared case's checkout."
  @spec cleanup(prepared()) :: :ok | {:error, term()}
  def cleanup(%{worktree: worktree}), do: remove_checkout(worktree)

  defp remove_checkout(worktree) do
    cond do
      not File.exists?(worktree) ->
        :ok

      File.regular?(Path.join([worktree, ".git", @marker])) ->
        case File.rm_rf(worktree) do
          {:ok, _removed} -> :ok
          {:error, reason, path} -> {:error, {:cleanup_failed, path, reason}}
        end

      true ->
        {:error, {:not_a_checkout, worktree}}
    end
  end

  # Deletes the clone's remote, branches, tags, and reflogs; the detached
  # HEAD keeps the checked-out commit.
  defp strip_refs(worktree) do
    with {:ok, _out} <- git(worktree, ["remote", "remove", "origin"]),
         {:ok, refs} <- git(worktree, ["for-each-ref", "--format=%(refname)"]),
         :ok <- delete_refs(worktree, String.split(refs, "\n", trim: true)),
         {:ok, _out} <- git(worktree, ["reflog", "expire", "--expire=now", "--all"]) do
      :ok
    end
  end

  defp delete_refs(worktree, refs) do
    Enum.reduce_while(refs, :ok, fn ref, :ok ->
      case git(worktree, ["update-ref", "-d", ref]) do
        {:ok, _out} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp apply_edits(kase, worktree) do
    Enum.reduce_while(kase.edits, :ok, fn edit, :ok ->
      case apply_edit(edit, worktree) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp apply_edit(edit, worktree) do
    path = Path.join(worktree, edit.path)

    with {:ok, text} <- read(path, edit.path) do
      case :binary.matches(text, edit.find) do
        [_one] -> File.write(path, String.replace(text, edit.find, edit.replace, global: false))
        [] -> {:error, {:edit_not_found, edit.path, edit.find}}
        _many -> {:error, {:edit_ambiguous, edit.path, edit.find}}
      end
    end
  end

  # The edits become part of the case's commit, with its message and
  # author, so neither a seed commit nor its message shows in the range.
  defp amend_edits(%__MODULE__{edits: []}, _worktree), do: :ok

  defp amend_edits(_kase, worktree) do
    with {:ok, _out} <- git(worktree, ["add", "--all"]),
         {:ok, _out} <-
           git(
             worktree,
             @git_identity ++
               ["commit", "--quiet", "--no-verify", "--amend", "--reuse-message=HEAD"]
           ),
         {:ok, _out} <- git(worktree, ["reflog", "expire", "--expire=now", "--all"]) do
      :ok
    end
  end

  defp locate_issues(kase, worktree) do
    Enum.reduce_while(kase.issues, {:ok, []}, fn issue, {:ok, acc} ->
      case locate(issue, worktree) do
        {:ok, located} -> {:cont, {:ok, [located | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, located} -> {:ok, Enum.reverse(located)}
      error -> error
    end
  end

  defp locate(issue, worktree) do
    [issue | issue.also]
    |> Enum.reduce_while({:ok, []}, fn place, {:ok, acc} ->
      with {:ok, text} <- read(Path.join(worktree, place.path), place.path),
           {:ok, location} <- locate_in(place, text) do
        {:cont, {:ok, [location | acc]}}
      else
        {:error, {:anchor_not_found, anchor}} ->
          {:halt, {:error, {:anchor_not_found, issue.id, place.path, anchor}}}

        {:error, {:anchor_ambiguous, anchor}} ->
          {:halt, {:error, {:anchor_ambiguous, issue.id, place.path, anchor}}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, locations} ->
        {:ok,
         %{
           id: issue.id,
           locations: Enum.reverse(locations),
           keywords: issue.keywords,
           description: issue.description
         }}

      error ->
        error
    end
  end

  @doc """
  Locates a place in the file contents `text`: the line where its anchor,
  which must occur exactly once (and may span lines), starts, and the
  `lines - 1` following ones.
  """
  @spec locate_in(place(), String.t()) ::
          {:ok, location()} | {:error, {:anchor_not_found | :anchor_ambiguous, String.t()}}
  def locate_in(place, text) do
    case :binary.matches(text, place.anchor) do
      [{offset, _length}] ->
        start = count_newlines(binary_part(text, 0, offset)) + 1
        last = count_newlines(text) + 1

        {:ok,
         %{path: place.path, start_line: start, end_line: min(start + place.lines - 1, last)}}

      [] ->
        {:error, {:anchor_not_found, place.anchor}}

      _many ->
        {:error, {:anchor_ambiguous, place.anchor}}
    end
  end

  defp count_newlines(text), do: length(:binary.matches(text, "\n"))

  defp read(path, relative) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, {:unreadable, relative, reason}}
    end
  end

  defp rev_parse(dir, rev) do
    case git(dir, ["rev-parse", "--verify", "--quiet", rev]) do
      {:ok, sha} -> {:ok, String.trim(sha)}
      {:error, _reason} -> {:error, {:unknown_revision, rev}}
    end
  end

  defp git(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, status} -> {:error, {:git_failed, args, status, String.trim(out)}}
    end
  end
end
