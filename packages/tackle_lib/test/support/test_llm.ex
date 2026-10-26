defmodule Tackle.Lib.TestLLM do
  @moduledoc false

  # Selects a fake adapter for one state (`State.new(llm: selection)`) instead
  # of configuring the application's default adapter, so loop tests do not
  # share global configuration and can run concurrently.

  alias Tackle.Lib.LLM
  alias Tackle.Lib.LLM.Selection

  @doc """
  Selects `adapter` with the adapter-local `model` from the provider `"test"`.

  The adapter receives `model` as the `:model` option, as it would through
  the configured adapter with `State.new(model: model)`, and the selection
  carries the adapter's `model_info/1` when it has one.
  """
  @spec selection(module(), String.t()) :: Selection.t()
  def selection(adapter, model \\ "test/model") when is_atom(adapter) and is_binary(model) do
    {:ok, model_info} = LLM.model_info(adapter, model)

    %Selection{
      adapter: adapter,
      provider_id: "test",
      model: model,
      ref: "test/" <> model,
      model_info: model_info
    }
  end
end
