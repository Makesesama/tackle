defmodule Tackle.Lib.ID do
  @moduledoc """
  Built-in id generators for Tackle.Lib structs.

  Tackle.Lib is persistence-agnostic, so hosts may supply their own generator via
  `Tackle.Lib.State.new/1` / `Tackle.Lib.new/1` using the `:id_generator` option. The
  default is UUIDv4 because it is broadly portable and works with many database
  schemas without requiring an Ecto dependency.
  """

  @type generator :: (-> String.t())

  @doc """
  Generates an RFC 4122 UUIDv4 string using `:crypto`.
  """
  @spec uuid4() :: String.t()
  def uuid4 do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    # Set the version (4) and variant (RFC 4122) bits.
    c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000)
    d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end
end
