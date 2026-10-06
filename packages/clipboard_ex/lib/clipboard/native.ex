defmodule Clipboard.Native do
  @moduledoc false
  # Thin NIF bindings over Rust's `arboard`. Every function runs on a dirty I/O
  # scheduler because the display server may block. Callers go through
  # `Clipboard.Owner`, which keeps the handle alive so Linux clipboard
  # contents stay available after a copy.
  #
  # Reasons are atoms (`:content_not_available`, `:clipboard_not_supported`,
  # `:clipboard_occupied`, `:conversion_failure`, `:unsupported_selection`,
  # `:invalid_image`, `:out_of_memory`, `:closed`) or `{:unknown, description}`.

  use Rustler, otp_app: :clipboard_ex, crate: "clipboard_ex"

  @type handle :: reference()
  @type selection :: :clipboard | :primary | :secondary
  @type reason :: atom() | {:unknown, String.t()}

  @spec new() :: {:ok, handle()} | {:error, reason()}
  def new, do: :erlang.nif_error(:nif_not_loaded)

  @spec set_text(handle(), selection(), String.t()) :: :ok | {:error, reason()}
  def set_text(_handle, _selection, _text), do: :erlang.nif_error(:nif_not_loaded)

  @spec set_html(handle(), selection(), String.t(), String.t() | nil) :: :ok | {:error, reason()}
  def set_html(_handle, _selection, _html, _alt_text), do: :erlang.nif_error(:nif_not_loaded)

  @spec get_text(handle(), selection()) :: {:ok, String.t()} | {:error, reason()}
  def get_text(_handle, _selection), do: :erlang.nif_error(:nif_not_loaded)

  @spec get_html(handle(), selection()) :: {:ok, String.t()} | {:error, reason()}
  def get_html(_handle, _selection), do: :erlang.nif_error(:nif_not_loaded)

  @spec set_image(handle(), selection(), pos_integer(), pos_integer(), binary()) ::
          :ok | {:error, reason()}
  def set_image(_handle, _selection, _width, _height, _rgba),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec get_image(handle(), selection()) ::
          {:ok, {pos_integer(), pos_integer(), binary()}} | {:error, reason()}
  def get_image(_handle, _selection), do: :erlang.nif_error(:nif_not_loaded)

  @spec clear(handle(), selection()) :: :ok | {:error, reason()}
  def clear(_handle, _selection), do: :erlang.nif_error(:nif_not_loaded)

  # Releases the clipboard on a dirty scheduler; later calls return
  # `{:error, :closed}`.
  @spec close(handle()) :: :ok
  def close(_handle), do: :erlang.nif_error(:nif_not_loaded)
end
