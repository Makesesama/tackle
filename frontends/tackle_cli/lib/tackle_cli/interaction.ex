defmodule Tackle.CLI.Interaction do
  @moduledoc false

  @behaviour Tackle.Lib.Interaction

  @reference :stdio

  @doc "Returns the interaction handle backed by the terminal."
  @spec handle() :: Tackle.Lib.Interaction.handle()
  def handle, do: {__MODULE__, @reference}

  @impl true
  def info(@reference, message), do: Owl.IO.puts(message)

  @impl true
  def prompt(@reference, opts) do
    label = Keyword.get(opts, :label, "Value")
    secret = Keyword.get(opts, :secret, false) == true

    value = Owl.IO.input(label: label, secret: secret, cast: :string)
    {:ok, value}
  rescue
    exception -> {:error, {:prompt_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:prompt_failed, {kind, reason}}}
  end

  @impl true
  def confirm(@reference, message) do
    Owl.IO.confirm(message: message) == true
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  @impl true
  def progress(@reference, opts, fun) when is_function(fun, 0) do
    Owl.Spinner.run(fun,
      labels: [
        processing: Keyword.get(opts, :label, "Working..."),
        ok: Keyword.get(opts, :ok, "Done"),
        error: Keyword.get(opts, :error, fn reason -> "Failed: #{inspect(reason)}" end)
      ]
    )
  end
end
