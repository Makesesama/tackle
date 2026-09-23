defmodule Tackle.CLI.Native do
  @moduledoc false

  use Rustler,
    otp_app: :tackle_cli,
    crate: "tackle",
    path: "native/tackle"

  # Private wire format: rows of {text, fg, bg, underline_color, modifier_bits}.
  # Colors are nil (reset), an ANSI palette index, or {r, g, b}.
  def input_new, do: :erlang.nif_error(:nif_not_loaded)
  def input_get_value(_state), do: :erlang.nif_error(:nif_not_loaded)
  def input_set_value(_state, _value), do: :erlang.nif_error(:nif_not_loaded)
  def input_insert_str(_state, _value), do: :erlang.nif_error(:nif_not_loaded)
  def input_handle_key(_state, _code, _modifiers, _width), do: :erlang.nif_error(:nif_not_loaded)
  def input_rows(_state, _width), do: :erlang.nif_error(:nif_not_loaded)

  def input_render(_state, _width, _height, _placeholder, _focused),
    do: :erlang.nif_error(:nif_not_loaded)

  def browse_document(_source, _width, _style), do: :erlang.nif_error(:nif_not_loaded)
  def browse_scroll(_offset, _total, _height, _delta), do: :erlang.nif_error(:nif_not_loaded)

  def browse_render(_state, _page, _width, _height, _offset, _selected, _styles),
    do: :erlang.nif_error(:nif_not_loaded)

  def conversation_markdown(_source, _width, _style), do: :erlang.nif_error(:nif_not_loaded)

  def conversation_message(_source, _width, _markdown, _style, _marker),
    do: :erlang.nif_error(:nif_not_loaded)

  def conversation_rows(_rows, _width), do: :erlang.nif_error(:nif_not_loaded)

  def conversation_code(_rows, _width, _style, _marker, _language),
    do: :erlang.nif_error(:nif_not_loaded)

  def conversation_new(_cells, _width), do: :erlang.nif_error(:nif_not_loaded)

  def conversation_render(_state, _width, _height, _offset, _selected, _selection),
    do: :erlang.nif_error(:nif_not_loaded)

  # Edit preview rows: `{:del | :ins | :ctx, number, [{text, emphasized}]}` or
  # `{:elision, count}`, with the counts of added and removed lines. `similar`
  # does the matching and the intraline emphasis in Rust.
  def diff_rows(_old, _new, _context, _max_rows), do: :erlang.nif_error(:nif_not_loaded)

  def subagents_render(
        _tasks,
        _width,
        _height,
        _accent,
        _muted,
        _text,
        _selected,
        _spinner_frame
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  def tree_render(_nodes, _selected, _width, _height, _accent, _muted, _selection, _text),
    do: :erlang.nif_error(:nif_not_loaded)

  def badge(_label, _width, _height), do: :erlang.nif_error(:nif_not_loaded)
end
