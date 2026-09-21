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

  def message({:unknown_adapter, adapter_id}) do
    "The provider #{adapter_id} is not configured. Check `config :tackle, :adapters`."
  end

  def message({:invalid_model_ref, model_ref}) do
    "#{inspect(model_ref)} is not an `adapter/model` reference."
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
