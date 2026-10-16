defmodule Tackle.Web.DataCase do
  @moduledoc """
  Tests that use the database. Each test runs in a sandboxed transaction
  that is rolled back at the end; `async: true` tests get their own.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Tackle.Web.DataCase
    end
  end

  setup tags do
    setup_sandbox(tags)
    :ok
  end

  @doc "Checks out a sandboxed connection, shared unless the test is async."
  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(Tackle.Web.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end
end
