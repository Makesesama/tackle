defmodule Clipboard.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [Clipboard.Owner]
    Supervisor.start_link(children, strategy: :one_for_one, name: Clipboard.Supervisor)
  end
end
