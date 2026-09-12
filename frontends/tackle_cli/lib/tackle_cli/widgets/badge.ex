defmodule Tackle.CLI.Widgets.Badge do
  @moduledoc """
  A small Rust-rendered example widget, usable in any top-level TUI scene.

      {%Tackle.CLI.Widgets.Badge{label: "Native"}, rect}

  Rendering is stateless and opaque (including blank cells). Terminal control
  sequences are stripped before paint. Labels are limited to 4,096 UTF-8 bytes
  and the supplied area to 65,536 cells; invalid input raises `ArgumentError`
  through the widget protocol. `render/2` exposes expected errors as tuples.
  """

  alias ExRatatui.Layout.Rect
  alias Tackle.CLI.Native
  alias Tackle.CLI.TUI.MessageView
  alias Tackle.CLI.Widgets.Surface

  defstruct label: ""

  @type t :: %__MODULE__{label: String.t()}

  @doc "Renders into placed ExRatatui primitives without opening a terminal."
  @spec render(t(), Rect.t()) :: {:ok, [{struct(), Rect.t()}]} | {:error, term()}
  def render(%__MODULE__{label: label}, %Rect{width: width, height: height} = rect)
      when is_binary(label) and is_integer(width) and is_integer(height) do
    with :ok <- validate_area(width, height),
         :ok <- validate_label(label),
         {:ok, rows} <- Native.badge(sanitize(label), width, height) do
      {:ok, Surface.place(rows, rect)}
    end
  end

  def render(%__MODULE__{}, %Rect{}), do: {:error, :invalid_widget}

  defp validate_area(width, height)
       when width >= 0 and height >= 0 and width <= 65_535 and height <= 65_535 do
    if width * height > 65_536, do: {:error, :invalid_size}, else: :ok
  end

  defp validate_area(_width, _height), do: {:error, :invalid_widget}

  defp validate_label(label) when byte_size(label) > 4_096, do: {:error, :label_too_long}

  defp validate_label(label) do
    if String.valid?(label), do: :ok, else: {:error, :invalid_label}
  end

  defp sanitize(label), do: label |> MessageView.sanitize() |> String.replace("\n", " ")

  defimpl ExRatatui.Widget do
    alias Tackle.CLI.Widgets.Badge

    def render(widget, rect) do
      case Badge.render(widget, rect) do
        {:ok, children} -> children
        {:error, reason} -> raise ArgumentError, "cannot render native badge: #{inspect(reason)}"
      end
    end
  end
end
