defmodule Tackle.Lib.Decision.Result do
  @moduledoc """
  The result of one decision request.

  `answers` is keyed by question name. `usage` is normalized into
  `Tackle.Lib.Usage` by `Tackle.Lib.Decision.decide/3`.
  """

  alias Tackle.Lib.Decision.Answer

  @enforce_keys [:answers]
  defstruct [:model, :usage, answers: %{}]

  @type t :: %__MODULE__{
          model: String.t() | nil,
          answers: %{required(String.t()) => Answer.t()},
          usage: Tackle.Lib.Usage.t() | map() | nil
        }
end
