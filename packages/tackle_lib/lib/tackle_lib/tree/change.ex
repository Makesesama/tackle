defmodule Tackle.Lib.Tree.Change do
  @moduledoc """
  Provider-neutral description of one navigation.

  A change is what the state's `Tackle.Lib.Committer` persists before the
  library installs the new active position. It is deliberately plain: ids and
  a revision, never entries or runtime state. The tree itself is unchanged by
  navigation, so a host only has to durably record where the conversation
  moved to.

  `:from_id` is the active position before the navigation, `:to_id` the
  destination, and `:revision` the tree's revision after it. Selecting the
  current position changes nothing: `:from_id` equals `:to_id`, the revision
  stays, and the change is never committed.

  `:mode` distinguishes a plain move from an edit-target selection. In `:edit`
  mode the selected entry is the user message being edited and `:to_id` is its
  parent, so submitting the edited text creates a sibling branch.
  """

  @type mode :: :move | :edit

  @type t :: %__MODULE__{
          from_id: String.t() | nil,
          to_id: String.t() | nil,
          selected_id: String.t() | nil,
          mode: mode(),
          revision: non_neg_integer()
        }

  @enforce_keys [:revision]
  defstruct from_id: nil,
            to_id: nil,
            selected_id: nil,
            mode: :move,
            revision: 0
end
