defmodule Tackle.PromptRenderer do
  @moduledoc """
  Behaviour for rendering prompt-facing tool and response guidance sections.

  A prompt renderer owns the human-readable text that a model sees for a
  surface. Tool execution itself uses provider-native tool calling; JSON schemas
  are reserved for tool input definitions and optional structured non-tool
  responses.
  """

  @type opts :: keyword()

  @callback render_tools([module()], opts()) :: String.t()
  @callback render_response_format(opts()) :: String.t()
  @callback response_schema(opts()) :: keyword() | map() | nil

  @default_renderer Tackle.PromptRenderer.NativeTools

  @doc "Returns the configured prompt renderer module."
  @spec configured_renderer() :: module()
  def configured_renderer do
    Application.get_env(:tackle, :prompt_renderer) ||
      get_in(Application.get_env(:my_app, Tackle, []), [:prompt_renderer]) ||
      @default_renderer
  end

  @doc "Returns configured renderer options."
  @spec configured_opts() :: keyword()
  def configured_opts do
    Application.get_env(:tackle, :prompt_renderer_opts) ||
      get_in(Application.get_env(:my_app, Tackle, []), [:prompt_renderer_opts]) ||
      []
  end

  @doc "Resolves renderer options from explicit opts plus config defaults."
  @spec resolve(keyword()) :: {module(), keyword()}
  def resolve(opts \\ []) do
    renderer = Keyword.get(opts, :prompt_renderer) || configured_renderer()

    explicit_renderer_opts = Keyword.get(opts, :prompt_renderer_opts) || []

    renderer_opts =
      configured_opts()
      |> Keyword.merge(explicit_renderer_opts)
      |> Keyword.merge(Keyword.drop(opts, [:prompt_renderer, :prompt_renderer_opts, :title]))

    {renderer, renderer_opts}
  end
end
