defmodule Tackle.Lib.TestLLM do
  @moduledoc false

  # Selects a fake adapter for one state (`State.new(llm: selection)`), the
  # only way to give a loop an adapter, so loop tests share no global
  # configuration and can run concurrently.

  alias Tackle.Lib.LLM
  alias Tackle.Lib.LLM.Selection

  @doc """
  Selects `adapter` with the adapter-local `model` from the provider `"test"`.

  The adapter receives `model` as the `:model` option, and the selection
  carries the adapter's `model_info/1` when it has one. Unlike
  `Tackle.Lib.LLM.select/2`, the adapter needs no `adapter_id/0` or
  `models/0`.
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
