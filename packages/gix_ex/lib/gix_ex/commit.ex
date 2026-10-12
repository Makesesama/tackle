defmodule GixEx.Commit do
  @moduledoc """
  A commit listed by `GixEx.commits/4`.

  `subject` and `body` split the message as `git log --format=%s` and `%b`
  do: the subject is the first paragraph with its lines joined by spaces, the
  body everything after the blank lines that follow it.
  """

  @enforce_keys [:id, :subject, :body]
  defstruct [:id, :subject, :body]

  @type t :: %__MODULE__{id: String.t(), subject: binary(), body: binary()}
end
