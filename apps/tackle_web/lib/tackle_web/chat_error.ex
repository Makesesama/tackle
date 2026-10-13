defmodule Tackle.Web.ChatError do
  @moduledoc """
  Turns the failures a chat can run into into something a reader can act on.

  The chat surfaces errors that come from four different layers — the in-memory
  store, the harness configuration, model resolution, and the Runner's turn gate
  — and those layers report precise but internal terms such as
  `{:unknown_model, "openai-codex/nope"}`. A reader of the page needs to know
  what to change (a model name, a directory, a provider login), so this module
  is the one place that translates them.

  Anything unrecognized is still shown, in `inspect/1` form: hiding an
  unexpected failure would make the page look like it silently did nothing.
  """

  @doc "A sentence describing `reason`, suitable for showing on the page."
  @spec message(term()) :: String.t()
  def message(:conversation_gone) do
    "This conversation is no longer in memory: it was deleted, or the server restarted."
  end

  def message(:no_model_available) do
    "No provider adapters are configured. Add one with `config :tackle, :adapters`."
  end

  def message(:turn_in_progress), do: "The assistant is already working on an answer."

  def message({:workspace_missing, path}) do
    "#{path} is not a directory that exists. Start the chat in a checkout or any other directory the assistant may read."
  end

  def message({:invalid_workspace, value}) do
    "#{inspect(value)} is not a directory path. Enter an absolute or relative directory."
  end

  def message({:invalid_option, :cwd, _cwd}) do
    "That working directory does not exist. Start the chat in a directory the assistant may read."
  end

  def message({:cwd_unavailable, _reason}) do
    "The working directory could not be resolved. Enter a directory the assistant may read."
  end

  def message({:unknown_model, model_ref}) do
    "#{model_ref} is not offered by the configured providers. Pick another model."
  end

  def message({:unknown_provider, provider_id}) do
    "The provider #{provider_id} is not configured. Declare it under \"providers\" in " <>
      "config.json, add it with `tackle auth login ADAPTER --as #{provider_id}`, or check " <>
      "`config :tackle, :adapters`."
  end

  def message({:invalid_model_ref, model_ref}) do
    "#{inspect(model_ref)} is not a `provider/model` reference."
  end

  def message(reason) when reason in [:no_adapters_configured, :no_providers_configured] do
    "No provider adapters are configured. Add one with `config :tackle, :adapters`."
  end

  def message({:duplicate_provider_id, provider_id}) do
    "The provider #{provider_id} is declared more than once."
  end

  def message({:provider_adapter_conflict, provider_id}) do
    "The provider #{provider_id} is declared with two different adapters. " <>
      "Check the \"providers\" object in config.json and the accounts from `tackle auth status`."
  end

  def message({:unknown_provider_adapter, provider_id, adapter_id}) do
    "The provider #{provider_id} in config.json names the adapter #{adapter_id}, " <>
      "which this server does not offer."
  end

  def message({:invalid_config_provider, path, provider_id}) do
    "The provider #{provider_id} in #{path} is invalid: it needs an \"adapter\" naming an " <>
      "adapter type id."
  end

  def message({:invalid_provider_setting, provider_id, key, _value}) do
    "The provider #{provider_id} has an invalid #{inspect(key)} setting in config.json."
  end

  def message({:invalid_provider_settings, provider_id, _detail}) do
    "The provider #{provider_id} has invalid settings in config.json."
  end

  def message({:accounts_unavailable, _reason}) do
    "The provider accounts recorded by `tackle auth login --as` could not be read."
  end

  def message({:invalid_option, :available_adapters, _adapters}) do
    "No provider adapters are configured. Add one with `config :tackle, :adapters`."
  end

  def message({:invalid_option, :model, _model}) do
    "That model could not be used. Pick another one."
  end

  def message({:missing_option, :model}) do
    "No model was selected and no default model is configured."
  end

  def message(reason) do
    "The assistant could not be started: #{inspect(reason)}"
  end
end
