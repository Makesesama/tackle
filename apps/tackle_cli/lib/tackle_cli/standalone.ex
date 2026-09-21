defmodule Tackle.CLI.Standalone do
  @moduledoc false

  use Task

  alias Burrito.Util
  alias Burrito.Util.Args
  alias Tackle.CLI.Main

  @spec start_link(term()) :: {:ok, pid()} | :ignore
  def start_link(_arg) do
    if Util.running_standalone?() do
      run(Args.argv())
      :ignore
    else
      Task.start_link(fn -> :ok end)
    end
  end

  defp run(argv) do
    status =
      try do
        Main.main(argv)
      rescue
        exception ->
          IO.puts(:stderr, "tackle crashed: " <> Exception.message(exception))
          1
      catch
        kind, reason ->
          IO.puts(:stderr, "tackle crashed: #{Exception.format_banner(kind, reason)}")
          1
      end

    System.halt(status)
  end
end
