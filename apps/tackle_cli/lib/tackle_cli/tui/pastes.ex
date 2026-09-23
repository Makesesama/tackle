defmodule Tackle.CLI.TUI.Pastes do
  @moduledoc """
  Keeps large pasted text and image instructions out of the composer while
  retaining their contents for submission. Tokens are scoped to a TUI session.
  """

  alias Tackle.CLI.TUI.State
  alias Tackle.CLI.Widgets.Input

  @long_text_bytes 1_000
  @token ~r/\[(?:image|text)-\d+\]/

  @doc "Whether a text paste is large enough to collapse in the composer."
  @spec long_text?(String.t()) :: boolean()
  def long_text?(text), do: byte_size(text) >= @long_text_bytes

  @doc "Inserts a token for a paste and retains its full value for submission."
  @spec insert(State.t(), :image | :text, String.t()) :: State.t()
  def insert(%State{} = state, kind, content) when kind in [:image, :text] do
    number = Map.fetch!(state.paste_counts, kind) + 1
    token = "[#{kind}-#{number}]"
    draft = Input.get_value(state.input)
    # Never reuse a token already present in the draft (including one typed by hand).
    {number, token} = unique_token(draft, state.paste_replacements, kind, number, token)
    prefix = if draft == "" or String.ends_with?(draft, [" ", "\n"]), do: "", else: " "
    :ok = Input.insert_str(state.input, prefix <> token)

    %{
      state
      | paste_counts: Map.put(state.paste_counts, kind, number),
        paste_replacements: Map.put(state.paste_replacements, token, content)
    }
  end

  @doc "Expands known tokens before a prompt is sent to the agent."
  @spec expand(String.t(), State.t()) :: String.t()
  def expand(text, %State{} = state) do
    Regex.replace(@token, text, fn token -> Map.get(state.paste_replacements, token, token) end)
  end

  @doc "Collapses retained paste contents in transcript previews."
  @spec collapse(String.t(), State.t()) :: String.t()
  def collapse(text, state) when is_binary(text) do
    replacements = Map.get(state, :paste_replacements, %{})

    replacements
    |> Enum.sort_by(fn {_token, value} -> -byte_size(value) end)
    |> Enum.reduce(text, fn {token, value}, acc ->
      if value == "" do
        acc
      else
        acc
        |> String.replace(value, token)
        |> String.replace(String.trim(value), token)
      end
    end)
  end

  defp unique_token(draft, replacements, kind, number, token) do
    if String.contains?(draft, token) or Map.has_key?(replacements, token) do
      next = number + 1
      unique_token(draft, replacements, kind, next, "[#{kind}-#{next}]")
    else
      {number, token}
    end
  end
end
