defmodule Tackle.Web.Router do
  @moduledoc false

  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", Tackle.Web do
    pipe_through :api

    get "/health", HealthController, :show
  end
end
