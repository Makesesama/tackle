defmodule Tackle.Hub.AccountsFixtures do
  @moduledoc "Users and signed-in test sessions."

  alias Tackle.Hub.Accounts.User

  @doc """
  A user as a sign-in records it. Users are admins only with `admin: true`,
  whether or not they are the first.
  """
  def user!(attrs \\ %{}) do
    id = System.unique_integer([:positive, :monotonic])

    user =
      User.sign_in!(%{
        forge: :github,
        external_id: Map.get(attrs, :external_id, Integer.to_string(id)),
        login: Map.get(attrs, :login, "user#{id}"),
        name: Map.get(attrs, :name)
      })

    admin? = Map.get(attrs, :admin, false)
    if user.admin == admin?, do: user, else: User.set_admin!(user, admin?)
  end

  def admin!(attrs \\ %{}), do: user!(Map.put(attrs, :admin, true))

  @doc "A test session signed in as `user`, `age` seconds ago."
  def sign_in(conn, user, age \\ 0) do
    Plug.Test.init_test_session(conn, %{
      "user_id" => user.id,
      "signed_in_at" => System.os_time(:second) - age
    })
  end
end
