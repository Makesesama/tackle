defmodule Tackle.CLI.Native do
  @moduledoc false

  use Rustler,
    otp_app: :tackle_cli,
    crate: "tackle",
    path: "native/tackle"

  # Private wire format: rows of {text, fg, bg, underline_color, modifier_bits}.
  # Colors are nil (reset), an ANSI palette index, or {r, g, b}.
  def input_new(), do: :erlang.nif_error(:nif_not_loaded)
  def input_get_value(_state), do: :erlang.nif_error(:nif_not_loaded)
  def input_set_value(_state, _value), do: :erlang.nif_error(:nif_not_loaded)
  def input_insert_str(_state, _value), do: :erlang.nif_error(:nif_not_loaded)
  def input_handle_key(_state, _code, _modifiers, _width), do: :erlang.nif_error(:nif_not_loaded)
  def input_rows(_state, _width), do: :erlang.nif_error(:nif_not_loaded)

  def input_render(_state, _width, _height, _placeholder, _focused),
    do: :erlang.nif_error(:nif_not_loaded)

  def conversation_markdown(_source, _width, _style), do: :erlang.nif_error(:nif_not_loaded)
  def conversation_rows(_rows, _width), do: :erlang.nif_error(:nif_not_loaded)
  def conversation_new(_cells, _width), do: :erlang.nif_error(:nif_not_loaded)

  def conversation_render(_state, _width, _height, _offset, _selected, _selection),
    do: :erlang.nif_error(:nif_not_loaded)

  def badge(_label, _width, _height), do: :erlang.nif_error(:nif_not_loaded)
end
