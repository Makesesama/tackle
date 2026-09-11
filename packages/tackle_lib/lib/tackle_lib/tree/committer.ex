defmodule Tackle.Lib.Tree.Committer do
  @moduledoc """
  Durability seam for one conversation-tree navigation.

  `Tackle.Lib` owns the in-memory transaction but is persistence-free. A
  committer makes a navigation durable before the library installs the new
  active position: the library calls `commit_navigation/2` and only installs the
  change when it returns `:ok`. A commit failure leaves the previously accepted
  position unchanged.

  A missing committer is valid only for explicitly in-memory use. The durable
  harness always supplies one.
  """

  alias Tackle.Lib.Tree.Change

  @callback commit_navigation(Change.t(), context :: map()) :: :ok | {:error, term()}
end
