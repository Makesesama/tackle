defmodule Tackle.Web.Project.Source do
  @moduledoc """
  What the app needs from a place code lives.

  Every screen reaches a project through this behaviour rather than through a
  source module, so nothing outside a source has to know whether the code is on
  local disk or on GitHub. The callbacks are exactly the questions the screens
  ask:

    * `build/1` — the add-project form: is this input a usable project, and what
      should it be called?
    * `checkout/1` — the working tree a chat runs in.
    * `branches/1` — what a review can be opened between.
    * `list_reviews/1` — reviews the project offers ready-made.
    * `load_review/2` — one review: its diff, its metadata, and the working tree
      the assistant reads for it.

  `branches/1` and `list_reviews/1` are allowed to be empty, and the project
  page renders whichever a source offers. A local repository has branches but no
  ready-made reviews; a GitHub repository has pull requests. Neither is a
  special case in the view.

  ## Implementing a source

  `build/1` returns the fields of a project, not a project: the slug and the
  timestamp belong to `Tackle.Web.ProjectStore`, and a source that could name
  its own slug could disagree with the store about it.
  """

  alias Tackle.Web.Project

  @typedoc "A branch a review can start from."
  @type branch :: %{name: String.t(), current?: boolean()}

  @typedoc "A ready-made review the project offers, such as an open pull request."
  @type review_summary :: %{
          review_id: String.t(),
          title: String.t(),
          author: String.t() | nil,
          base_ref: String.t() | nil,
          head_ref: String.t() | nil
        }

  @typedoc """
  Everything the review screen needs, loaded as one unit.

  `cwd` is a working tree at the review's head, which is what the assistant
  reads; the diff is computed from that same tree so the two cannot disagree.
  """
  @type loaded_review :: %{
          review_id: String.t(),
          title: String.t(),
          base_ref: String.t(),
          head_ref: String.t(),
          cwd: Path.t(),
          diff: Tackle.Web.Diff.diff(),
          project: Project.t()
        }

  @doc """
  Turns form input into the fields of a project.

  Returns `{:ok, fields}` with `:kind`, `:locator`, `:name` and
  `:default_branch`, or `{:error, message}` to show on the form.
  """
  @callback build(attrs :: map()) :: {:ok, map()} | {:error, String.t()}

  @doc """
  A working tree of the project, used as a chat's working directory.
  """
  @callback checkout(Project.t()) :: {:ok, Path.t()} | {:error, String.t()}

  @doc """
  The branches a review can be opened between.

  May be empty when the source does not think in branches.
  """
  @callback branches(Project.t()) :: {:ok, [branch()]} | {:error, String.t()}

  @doc """
  Reviews the project offers without the reviewer describing them.

  May be empty when reviews are always described by the reviewer, as in a local
  repository where a review is a choice of two refs.
  """
  @callback list_reviews(Project.t()) :: {:ok, [review_summary()]} | {:error, String.t()}

  @doc """
  Loads one review by the id the source chose for it.

  The id is opaque to everyone else: the store, the URL and the transcript only
  pass it back to the source that produced it.
  """
  @callback load_review(Project.t(), review_id :: String.t()) ::
              {:ok, loaded_review()} | {:error, String.t()}
end
