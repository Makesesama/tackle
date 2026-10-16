defmodule Tackle.Web.ConnCase do
  @moduledoc """
  Tests of the HTTP interface: a `Plug.Conn` in `conn` and a sandboxed
  database, as in `Tackle.Web.DataCase`.
  """

  use ExUnit.CaseTemplate

  alias Tackle.Web.DataCase

  using do
    quote do
      @endpoint Tackle.Web.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
    end
  end

  setup tags do
    DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
