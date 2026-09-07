defmodule Tackle.JSON do
  @moduledoc """
  JSON boundary used by Tackle.

  Tackle is intended to be embedded in many Elixir applications, so it does not
  hard-code JSON calls throughout the harness. Configure an adapter with:

      config :tackle, json: MyApp.JSONAdapter

  The adapter must implement this behaviour. If no adapter is configured,
  `Tackle.JSON.Default` is used, which delegates to Elixir's built-in `JSON`
  module.
  """

  @callback encode(term()) :: {:ok, String.t()} | {:error, term()}
  @callback encode!(term()) :: String.t() | no_return()
  @callback decode(String.t()) :: {:ok, term()} | {:error, term()}
  @callback decode!(String.t()) :: term() | no_return()

  @doc "Returns the configured JSON adapter."
  @spec adapter() :: module()
  def adapter do
    Application.get_env(:tackle, :json) ||
      Application.get_env(:my_app, Tackle, [])[:json] ||
      Tackle.JSON.Default
  end

  @doc "Encodes a term to JSON using the configured adapter."
  @spec encode(term()) :: {:ok, String.t()} | {:error, term()}
  def encode(term), do: adapter().encode(term)

  @doc "Encodes a term to JSON or raises using the configured adapter."
  @spec encode!(term()) :: String.t() | no_return()
  def encode!(term), do: adapter().encode!(term)

  @doc "Decodes JSON using the configured adapter."
  @spec decode(String.t()) :: {:ok, term()} | {:error, term()}
  def decode(json), do: adapter().decode(json)

  @doc "Decodes JSON or raises using the configured adapter."
  @spec decode!(String.t()) :: term() | no_return()
  def decode!(json), do: adapter().decode!(json)
end
