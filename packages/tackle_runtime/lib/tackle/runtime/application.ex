defmodule Tackle.Runtime.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    configure_cancellation_store()

    children = [
      {Tackle.Runtime.CancellationStore, []},
      {Tackle.Runtime.Registry, []},
      {Tackle.AgentSupervisor, name: Tackle.AgentSupervisor}
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Tackle.Runtime.Supervisor
    )
  end

  defp configure_cancellation_store do
    if is_nil(Application.get_env(:tackle_lib, :cancellation_store)) do
      Application.put_env(
        :tackle_lib,
        :cancellation_store,
        Tackle.Runtime.CancellationStore
      )
    end
  end
end
