defmodule Tackle.CLI.Native do
  @moduledoc false

  use Rustler,
    otp_app: :tackle_cli,
    crate: "tackle",
    path: "native/tackle"

  # Private wire format: rows of {text, fg, bg, underline_color, modifier_bits}.
  # Colors are nil (reset), an ANSI palette index, or {r, g, b}.
  def badge(_label, _width, _height), do: :erlang.nif_error(:nif_not_loaded)
end
