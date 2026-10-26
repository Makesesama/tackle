defmodule Tackle.Lib.SystemPrompt do
  @moduledoc """
  A small builder for composing a system prompt from markdown sections.

  The loop sends `state.system_prompt` as it is; hosts may build that string
  with these helpers. Tools reach the model through the provider-native tool
  definitions, so the prompt does not need to describe them.
  """

  @type section :: {String.t() | nil, String.t()}
  @type t :: %__MODULE__{sections: [section()]}

  defstruct sections: []

  @doc "Starts a composable system-prompt builder."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Appends a titled markdown section to the prompt builder.

  `title` is rendered as a level-2 heading. `body` is trimmed, so callers can
  pass heredocs naturally.
  """
  @spec add_section(t(), String.t(), String.t()) :: t()
  def add_section(%__MODULE__{} = prompt, title, body)
      when is_binary(title) and is_binary(body) do
    add(prompt, {title, String.trim(body)})
  end

  @doc "Appends raw markdown to the prompt builder without adding a heading."
  @spec add_raw(t(), String.t()) :: t()
  def add_raw(%__MODULE__{} = prompt, body) when is_binary(body) do
    add(prompt, {nil, String.trim(body)})
  end

  @doc "Renders the builder to a markdown prompt string."
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{sections: sections}) do
    sections
    |> Enum.map_join("\n\n", fn
      {nil, body} -> body
      {title, body} -> "## #{title}\n\n#{body}"
    end)
    |> Kernel.<>("\n")
  end

  defp add(%__MODULE__{sections: sections} = prompt, section) do
    %{prompt | sections: List.insert_at(sections, -1, section)}
  end
end
