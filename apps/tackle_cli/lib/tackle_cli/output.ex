defmodule Tackle.CLI.Output do
  @moduledoc """
  Shared output policy for non-interactive CLI commands.

  Command renderers return Owl data, while this module owns terminal width and
  semantic color decisions. Machine-readable renderers bypass styling entirely.
  """

  defstruct format: :human,
            color?: false,
            interactive?: false,
            width: 100,
            device: :stdio

  @type format :: :human | :plain | :json
  @type color_mode :: :auto | :always | :never

  @type t :: %__MODULE__{
          format: format(),
          color?: boolean(),
          interactive?: boolean(),
          width: pos_integer(),
          device: IO.device()
        }

  @doc "Builds output policy from parsed command options."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    device = Keyword.get(opts, :device, :stdio)
    terminal_width = Owl.IO.columns(device)
    interactive? = is_integer(terminal_width) and is_integer(Owl.IO.rows(device))
    format = Keyword.get(opts, :format, :human)
    color_mode = Keyword.get(opts, :color, :auto)

    %__MODULE__{
      format: format,
      color?: format == :human and color?(color_mode, interactive?),
      interactive?: interactive?,
      width: output_width(Keyword.get(opts, :width), terminal_width),
      device: device
    }
  end

  @doc "Applies a semantic style when color is enabled."
  @spec style(t(), atom(), Owl.Data.t()) :: Owl.Data.t()
  def style(%__MODULE__{color?: true}, role, data), do: Owl.Data.tag(data, style_for(role))
  def style(%__MODULE__{}, _role, data), do: data

  @doc "Writes rendered command output to its configured device."
  @spec puts(t(), Owl.Data.t()) :: :ok
  def puts(%__MODULE__{device: device}, data), do: Owl.IO.puts(data, device)

  defp color?(:always, _interactive?), do: true
  defp color?(:never, _interactive?), do: false

  defp color?(:auto, interactive?) do
    interactive? and is_nil(System.get_env("NO_COLOR")) and System.get_env("TERM") != "dumb"
  end

  defp output_width(width, _terminal_width) when is_integer(width) and width > 0, do: width
  defp output_width(_width, terminal_width) when is_integer(terminal_width), do: terminal_width
  defp output_width(_width, _terminal_width), do: 100

  defp style_for(:heading), do: :bright
  defp style_for(:accent), do: :cyan
  defp style_for(:success), do: :green
  defp style_for(:warning), do: :yellow
  defp style_for(:danger), do: :red
  defp style_for(:muted), do: :faint
  defp style_for(_role), do: :default_color
end
