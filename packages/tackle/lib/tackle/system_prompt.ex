defmodule Tackle.SystemPrompt do
  @moduledoc """
  System-prompt structural machinery for ReAct-style agents.

  Tackle provides small prompt-building helpers. Prompt-facing tool rendering and
  response guidance are delegated to a `Tackle.PromptRenderer` module so hosts
  can keep tool descriptions and optional structured-response schemas aligned for
  each surface. Tool execution uses provider-native tool calls, not prompt-level
  JSON envelopes.
  """

  alias Tackle.PromptRenderer

  @type section :: {String.t() | nil, String.t()}
  @type renderer_opts :: keyword()
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

  @doc """
  Appends the prompt-rendered tools section for the given tool modules.

  Options:

    * `:title` - section title, defaults to `"Available Tools"`
    * `:prompt_renderer` - `Tackle.PromptRenderer` implementation
    * `:prompt_renderer_opts` - options passed to the prompt renderer

  For compatibility, passing a module as the third argument is treated as the
  default renderer's `:description_renderer` option.
  """
  @spec add_tools(t(), [module()], renderer_opts() | module() | nil) :: t()
  def add_tools(%__MODULE__{} = prompt, tools, opts \\ []) do
    opts = normalize_tool_opts(opts)
    title = Keyword.get(opts, :title, "Available Tools")

    add_section(prompt, title, tool_descriptions(tools, opts))
  end

  @doc "Appends the prompt-rendered response-format section."
  @spec add_response_format(t(), renderer_opts()) :: t()
  def add_response_format(%__MODULE__{} = prompt, opts \\ []) do
    add_raw(prompt, response_format_section(opts))
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

  @doc "Computes a stable version ID for a system prompt string."
  @spec version_id(String.t() | nil) :: String.t() | nil
  def version_id(nil), do: nil

  def version_id(prompt) when is_binary(prompt) do
    prompt
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc "Builds the prompt-rendered tool-descriptions block."
  @spec tool_descriptions([module()], renderer_opts() | module() | nil) :: String.t()
  def tool_descriptions(tools, opts \\ []) do
    opts = normalize_tool_opts(opts)
    {renderer, renderer_opts} = PromptRenderer.resolve(opts)

    renderer.render_tools(tools, renderer_opts)
  end

  @doc "Returns the prompt-rendered response-format section."
  @spec response_format_section(renderer_opts()) :: String.t()
  def response_format_section(opts \\ []) do
    {renderer, renderer_opts} = PromptRenderer.resolve(normalize_renderer_opts(opts))

    renderer.render_response_format(renderer_opts)
  end

  @doc "Returns the optional structured-response schema for the configured prompt renderer."
  @spec response_schema(renderer_opts()) :: keyword() | map() | nil
  def response_schema(opts \\ []) do
    {renderer, renderer_opts} = PromptRenderer.resolve(normalize_renderer_opts(opts))

    renderer.response_schema(renderer_opts)
  end

  defp add(%__MODULE__{sections: sections} = prompt, section) do
    %{prompt | sections: sections ++ [section]}
  end

  defp normalize_tool_opts(nil), do: []
  defp normalize_tool_opts(opts) when is_list(opts), do: opts

  defp normalize_tool_opts(renderer) when is_atom(renderer) do
    [description_renderer: renderer]
  end

  defp normalize_renderer_opts(nil), do: []
  defp normalize_renderer_opts(opts) when is_list(opts), do: opts

  defp normalize_renderer_opts(renderer) when is_atom(renderer) do
    [prompt_renderer: renderer]
  end
end
