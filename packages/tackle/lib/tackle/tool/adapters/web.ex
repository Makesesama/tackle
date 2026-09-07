defmodule Tackle.Tool.Adapters.Web do
  @moduledoc """
  Adapts canonical `Tackle.Tool` modules for the web/agent loop.

  Today this adapter is intentionally thin: `use Tackle.Tool` modules already
  implement the callback API that `Tackle.State` and `Tackle.Tool.Registry`
  consume, so `wrap/1` returns validated modules unchanged. Keeping this small
  boundary gives callers a stable public API and leaves room for richer tool
  declarations later.

  ## Example

      state =
        Tackle.new(
          tools: Tackle.Tool.Adapters.Web.wrap([MyApp.Tools.Search]),
          context: %{user_id: user.id}
        )
  """

  @required_callbacks [
    {:name, 0},
    {:description, 0},
    {:parameters_schema, 0},
    {:execute, 2}
  ]

  @doc """
  Wraps one or more canonical Tackle tools for use by the web/agent runtime.

  The current implementation validates that every module exports the required
  `Tackle.Tool` callbacks and returns the modules unchanged.
  """
  @spec wrap(module() | [module()]) :: [module()]
  def wrap(tools) when is_list(tools), do: Enum.map(tools, &wrap_one/1)
  def wrap(tool), do: wrap([tool])

  defp wrap_one(tool) when is_atom(tool) do
    case missing_callbacks(tool) do
      [] ->
        tool

      missing ->
        raise ArgumentError,
              "#{inspect(tool)} is not a valid Tackle.Tool; missing callbacks: #{format_callbacks(missing)}"
    end
  end

  defp wrap_one(tool) do
    raise ArgumentError,
          "Tackle.Tool.Adapters.Web.wrap/1 expects a module or list of modules, got: #{inspect(tool)}"
  end

  defp missing_callbacks(tool) do
    if Code.ensure_loaded?(tool) do
      Enum.reject(@required_callbacks, fn {name, arity} ->
        function_exported?(tool, name, arity)
      end)
    else
      @required_callbacks
    end
  end

  defp format_callbacks(callbacks) do
    Enum.map_join(callbacks, ", ", fn {name, arity} -> "#{name}/#{arity}" end)
  end
end
