defmodule Tackle.Lib.Compaction.Committer do
  @moduledoc """
  Durability seam for one compaction.

  `Tackle.Lib` owns the in-memory transaction but is persistence-free. A
  committer makes the compaction durable before the model surface is replaced:
  the library calls `commit/2` and only installs the replacement when it
  returns `:ok`. A commit failure is fatal to the caller's durable execution —
  it must not continue with a model surface whose checkpoint was never
  persisted.

  Committers receive a `Tackle.Lib.Compaction.Record` and a context map. They
  are responsible for lowering the record into their own durable schema.
  """

  alias Tackle.Lib.Compaction.Record

  @callback commit(Record.t(), context :: map()) :: :ok | {:error, term()}
end
