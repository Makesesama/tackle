defmodule Tackle.Runtime.ID do
  @moduledoc """
  Stable identifier generation and validation for runtime entities.

  Runtime references are the public addressing model; PIDs never appear in a
  reference. Identifiers are opaque non-empty binaries with a conservative
  length bound so they are safe to log and route without truncation.
  """

  @max_bytes 128

  @typedoc "An opaque runtime identifier."
  @type t :: String.t()

  @doc "Generates a new unique runtime identifier."
  @spec generate() :: t()
  def generate, do: Tackle.Lib.ID.uuid4()

  @doc "Returns true when `value` is a valid runtime identifier."
  @spec valid?(term()) :: boolean()
  def valid?(value) when is_binary(value) do
    byte_size(value) > 0 and byte_size(value) <= @max_bytes
  end

  def valid?(_value), do: false
end
