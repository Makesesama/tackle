defmodule Tackle.HubWeb.ConnCase do
  @moduledoc """
  Tests of the HTTP interface: a `Plug.Conn` in `conn` and a sandboxed
  database, as in `Tackle.Hub.DataCase`.
  """

  use ExUnit.CaseTemplate

  alias Tackle.Hub.DataCase

  using do
    quote do
      @endpoint Tackle.HubWeb.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
    end
  end

  setup tags do
    DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
