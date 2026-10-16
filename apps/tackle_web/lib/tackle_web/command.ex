defmodule Tackle.Web.Command do
  @moduledoc """
  Parses review commands in pull request comments (docs/TACKLE_WEB_PLAN.md
  §7.7). The first line of the comment must be `/tackle review`, optionally
  followed by a profile (`quiet`, `default`, or `assertive`); later lines
  are free text.
  """

  alias Tackle.Web.Reviews.Profile

  @type t :: {:review, Profile.t() | nil}

  @doc """
  `{:review, profile}` for a review command (`profile` is nil when not
  given), `:none` for any other comment, or `{:error, reason}` for a
  malformed command.
  """
  @spec parse(String.t()) ::
          t() | :none | {:error, {:unknown_profile, String.t()} | :too_many_arguments}
  def parse(body) when is_binary(body) do
    first_line = body |> String.trim_leading() |> String.split("\n", parts: 2) |> hd()

    case String.split(first_line) do
      ["/tackle", "review"] ->
        {:review, nil}

      ["/tackle", "review", word] ->
        case Profile.match(word) do
          {:ok, profile} -> {:review, profile}
          :error -> {:error, {:unknown_profile, word}}
        end

      ["/tackle", "review" | _more] ->
        {:error, :too_many_arguments}

      _other ->
        :none
    end
  end
end
