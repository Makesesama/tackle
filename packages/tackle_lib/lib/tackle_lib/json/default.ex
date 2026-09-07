defmodule Tackle.Lib.JSON.Default do
  @moduledoc """
  Default `Tackle.Lib.JSON` adapter backed by Elixir's built-in `JSON` module.
  """

  @behaviour Tackle.Lib.JSON

  @impl true
  def encode(term) do
    {:ok, JSON.encode!(term)}
  rescue
    error -> {:error, error}
  end

  @impl true
  def encode!(term), do: JSON.encode!(term)

  @impl true
  def decode(json), do: JSON.decode(json)

  @impl true
  def decode!(json), do: JSON.decode!(json)
end
