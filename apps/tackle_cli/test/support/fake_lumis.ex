defmodule Tackle.CLI.Test.FakeLumis do
  @moduledoc false

  # A stand-in for Lumis: the same `highlight/2` contract, canned ANSI so the
  # suite never downloads a tree-sitter parser. Text before the first space is
  # painted with a token color; the rest of the line is left unstyled. The
  # color depends on the requested theme, so light and dark renders differ.
  @theme_colors %{
    "github_dark" => {1, 2, 3},
    "github_light" => {4, 5, 6}
  }

  def highlight(source, opts) do
    {:ok,
     source |> String.split("\n", trim: false) |> Enum.map_join("\n", &wrap(&1, color(opts)))}
  end

  defp color(opts) do
    case opts[:formatter] do
      {_formatter, formatter_opts} -> Map.fetch!(@theme_colors, formatter_opts[:theme])
      _ -> {1, 2, 3}
    end
  end

  defp wrap(line, {r, g, b}) do
    case String.split(line, " ", parts: 2) do
      [styled, plain] -> "\e[38;2;#{r};#{g};#{b}m#{styled} \e[0m#{plain}"
      [line] -> "\e[38;2;#{r};#{g};#{b}m#{line}\e[0m"
    end
  end
end

defmodule Tackle.CLI.Test.ErrorLumis do
  @moduledoc false

  # A stand-in for Lumis that cannot highlight anything: every call answers
  # with an error tuple, as an unloadable parser would.
  def highlight(_source, _opts), do: {:error, "language not loaded"}
end

defmodule Tackle.CLI.Test.RaisingLumis do
  @moduledoc false

  # A stand-in for a panicked NIF: highlighting raises instead of answering.
  def highlight(_source, _opts), do: raise(Lumis.HighlightError, error: :nif_panicked)
end

defmodule Tackle.CLI.Test.ReflowingLumis do
  @moduledoc false

  # A stand-in that renders one line fewer than the source has: the alignment
  # a diff relies on is gone, so no line may carry styling.
  def highlight(source, _opts) do
    {:ok, source |> String.split("\n", trim: false) |> Enum.take(1) |> Enum.join("\n")}
  end
end
