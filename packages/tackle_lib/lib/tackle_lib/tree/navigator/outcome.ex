defmodule Tackle.Lib.Tree.Navigator.Outcome do
  @moduledoc """
  What one navigation did (`Tackle.Lib.Tree.Navigator`).

    * `:change` - the `Tackle.Lib.Tree.Change`: where the position moved from
      and to, the selected entry, the mode, and the new revision;
    * `:draft` - in `:edit` mode, the selected user message, to edit and
      submit as a sibling branch; otherwise `nil`;
    * `:noop?` - true when the destination was already the active position,
      so nothing was committed or changed.
  """

  alias Tackle.Lib.Message
  alias Tackle.Lib.Tree.Change

  @type t :: %__MODULE__{
          change: Change.t(),
          draft: Message.t() | nil,
          noop?: boolean()
        }

  @enforce_keys [:change]
  defstruct change: nil, draft: nil, noop?: false
end
