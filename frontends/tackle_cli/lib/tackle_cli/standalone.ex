defmodule Tackle.CLI.Standalone do
  @moduledoc false

  use Task

  @spec start_link(term()) :: {:ok, pid()} | :ignore
  def start_link(_arg) do
    if Burrito.Util.running_standalone?() do
      run(Burrito.Util.Args.argv())
      :ignore
    else
      Task.start_link(fn -> :ok end)
    end
  end

  defp run(argv) do
    status =
      try do
        Tackle.CLI.Main.main(argv)
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
