defmodule GixEx.Native do
  @moduledoc false
  # NIF bindings over gitoxide; see `native/gix_ex/src/lib.rs`. Every function
  # runs on a dirty I/O scheduler. `GixEx` validates arguments and wraps the
  # results; reasons are documented on `t:GixEx.error/0`.

  use Rustler, otp_app: :gix_ex, crate: "gix_ex"

  @type repo :: reference()
  @type side :: {:rev, String.t()} | :empty | :worktree | :index

  @spec open(Path.t()) ::
          {:ok, {repo(), binary() | nil, binary()}} | {:error, GixEx.error()}
  def open(_path), do: :erlang.nif_error(:nif_not_loaded)

  @spec resolve(repo(), String.t()) :: {:ok, String.t()} | {:error, GixEx.error()}
  def resolve(_repo, _rev), do: :erlang.nif_error(:nif_not_loaded)

  @spec merge_base(repo(), String.t(), String.t()) :: {:ok, String.t()} | {:error, GixEx.error()}
  def merge_base(_repo, _one, _two), do: :erlang.nif_error(:nif_not_loaded)

  @spec symbolic_ref(repo(), String.t()) :: {:ok, {binary(), binary()}} | {:error, GixEx.error()}
  def symbolic_ref(_repo, _name), do: :erlang.nif_error(:nif_not_loaded)

  @spec empty_tree(repo()) :: String.t()
  def empty_tree(_repo), do: :erlang.nif_error(:nif_not_loaded)

  @spec commits(repo(), String.t() | nil, String.t(), non_neg_integer() | nil) ::
          {:ok, [GixEx.Commit.t()]} | {:error, GixEx.error()}
  def commits(_repo, _base, _head, _limit), do: :erlang.nif_error(:nif_not_loaded)

  @spec diff(repo(), side(), side(), map()) ::
          {:ok, [GixEx.Diff.File.t()]} | {:error, GixEx.error()}
  def diff(_repo, _from, _to, _options), do: :erlang.nif_error(:nif_not_loaded)
end
