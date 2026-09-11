defmodule Tackle.Lib.Tree.Change do
  @moduledoc """
  Provider-neutral description of one committed navigation.

  A change is what a host committer persists before the library installs the new
  active position. It is deliberately plain: ids and a revision, never entries
  or runtime state. The tree itself is unchanged by navigation, so a host only
  has to durably record where the conversation moved to.

  `:mode` distinguishes a plain move from an edit-target selection. In `:edit`
  mode the selected entry is the user message being edited and `:to_id` is its
  parent, so submitting the edited text creates a sibling branch.
  """

  @type mode :: :move | :edit

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          from_id: String.t() | nil,
          to_id: String.t() | nil,
          selected_id: String.t() | nil,
          mode: mode(),
          revision: non_neg_integer()
        }

  @enforce_keys [:revision]
  defstruct session_id: nil,
            from_id: nil,
            to_id: nil,
            selected_id: nil,
            mode: :move,
            revision: 0
end
