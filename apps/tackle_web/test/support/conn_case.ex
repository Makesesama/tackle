defmodule Tackle.Web.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Tackle.Web.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  import ExUnit.Assertions, only: [flunk: 1]
  import Phoenix.LiveViewTest, only: [render: 1]

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint Tackle.Web.Endpoint

      use Tackle.Web, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import Tackle.Web.ConnCase
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Waits until the rendered page contains `text`.

  An assistant turn runs in a supervised task, so its result arrives as a PubSub
  message some time after the click or submit that asked for it. Asserting on the
  next render is a race; this is the wait both assistant surfaces test with.
  """
  @spec eventually(Phoenix.LiveViewTest.View.t(), String.t(), pos_integer()) :: :ok
  def eventually(view, text, attempts \\ 100) do
    outcome =
      Enum.reduce_while(1..attempts, :timeout, fn _attempt, _acc ->
        if render(view) =~ text do
          {:halt, :found}
        else
          Process.sleep(20)
          {:cont, :timeout}
        end
      end)

    if outcome == :timeout do
      flunk("The page never showed #{inspect(text)}.")
    end

    :ok
  end
end
