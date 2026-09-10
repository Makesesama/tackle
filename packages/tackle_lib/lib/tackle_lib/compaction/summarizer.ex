defmodule Tackle.Lib.Compaction.Summarizer do
  @moduledoc """
  Behaviour for compaction summarizers.

  The core (`Tackle.Lib.Compaction`) owns selection, the transaction, validation,
  and replacement. A summarizer only turns a `Tackle.Lib.Compaction.Request`
  into a `Tackle.Lib.Compaction.Summary` — text plus bounded metadata and usage.

  Alternate summarizers (for example an observational-memory renderer) can be
  plugged in without being able to bypass tool-boundary or durability
  invariants.
  """

  alias Tackle.Lib.Compaction.Request
  alias Tackle.Lib.Compaction.Summary

  @callback summarize(Request.t(), keyword()) :: {:ok, Summary.t()} | {:error, term()}
end
