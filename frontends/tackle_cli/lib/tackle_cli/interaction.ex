defmodule Tackle.CLI.Interaction do
  @moduledoc false

  alias Tackle.CLI.Output

  @behaviour Tackle.Lib.Interaction

  @doc "Returns the interaction handle backed by the terminal."
  @spec handle(Output.t()) :: Tackle.Lib.Interaction.handle()
  def handle(%Output{} = output), do: {__MODULE__, output}

  @impl true
  def info(%Output{} = output, message), do: Output.puts(output, message)

  @impl true
  def prompt(%Output{} = output, opts) do
    label = Keyword.get(opts, :label, "Value")
    secret = Keyword.get(opts, :secret, false) == true
    label = Output.style(output, :heading, label)

    value = Owl.IO.input(label: label, secret: secret, cast: :string)
    {:ok, value}
  rescue
    exception -> {:error, {:prompt_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:prompt_failed, {kind, reason}}}
  end

  @impl true
  def confirm(%Output{} = output, message) do
    Owl.IO.confirm(message: Output.style(output, :warning, message)) == true
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  @impl true
  def progress(%Output{} = output, opts, fun) when is_function(fun, 0) do
    if output.interactive? do
      frames =
        if output.color? do
          []
        else
          [
            processing: ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"],
            ok: "✓",
            error: "✗"
          ]
        end

      Owl.Spinner.run(fun,
        frames: frames,
        labels: [
          processing: Keyword.get(opts, :label, "Working..."),
          ok: Keyword.get(opts, :ok, "Done"),
          error: Keyword.get(opts, :error, fn _reason -> "Failed" end)
        ]
      )
    else
      fun.()
    end
  end
end
