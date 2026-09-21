defmodule Tackle.Web.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Tackle.Web.Telemetry,
      {Phoenix.PubSub, name: Tackle.Web.PubSub},
      # Review state (comments and viewed markers) is shared by every viewer of a
      # pull request, so it lives in one process above the LiveViews. Chat
      # conversations and projects are shared the same way, but only in memory.
      Tackle.Web.ProjectStore,
      Tackle.Web.ReviewStore,
      Tackle.Web.ChatStore,
      # Agent infrastructure for Tackle.Phoenix.Runner: one Runner per pull
      # request conversation, started on demand and supervised apart from the
      # endpoint so a crashed turn cannot take the web server with it.
      {Registry, keys: :unique, name: Tackle.Web.AgentRegistry},
      {DynamicSupervisor,
       name: Tackle.Web.AgentSupervisor, strategy: :one_for_one, max_restarts: 5, max_seconds: 60},
      {Task.Supervisor, name: Tackle.Web.AgentTaskSupervisor},
      # Start to serve requests, typically the last entry
      Tackle.Web.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Tackle.Web.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    Tackle.Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
