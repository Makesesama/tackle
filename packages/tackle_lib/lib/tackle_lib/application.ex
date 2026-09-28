defmodule Tackle.Lib.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([Tackle.Lib.Cancellation.Store.Ets],
      strategy: :one_for_one,
      name: Tackle.Lib.Supervisor
    )
  end
end
