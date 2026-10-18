defmodule Tackle.Hub.AccountsTest do
  use Tackle.Hub.DataCase, async: false

  import Tackle.Hub.AccountsFixtures

  alias Tackle.Hub.Accounts.User
  alias Tackle.Hub.Release

  defp sign_in!(external_id, login, name \\ nil) do
    User.sign_in!(%{forge: :github, external_id: external_id, login: login, name: name})
  end

  defp claim(external_id, login),
    do: %{forge: :github, external_id: external_id, login: login, claim_admin: true}

  describe "sign_in" do
    test "never makes anyone an admin by itself, not even the first user" do
      refute sign_in!("1", "ada").admin
      refute sign_in!("2", "grace").admin
    end

    test "a setup claim makes the user an admin only while nobody is one" do
      sign_in!("1", "ada")

      # Someone who had signed in before can claim it.
      assert %{admin: true} = User.sign_in!(claim("1", "ada"))
      refute User.sign_in!(claim("2", "grace")).admin
    end

    test "updates login and name on a later sign-in, but never the admin flag" do
      admin!()
      user = sign_in!("2", "grace")
      User.set_admin!(user, true)

      again = sign_in!("2", "grace-h", "Grace Hopper")

      assert again.id == user.id
      assert again.login == "grace-h"
      assert again.name == "Grace Hopper"
      assert again.admin

      User.set_admin!(again, false)
      refute sign_in!("2", "grace-h").admin
    end
  end

  describe "set_admin" do
    test "admins grant and revoke it; other users cannot" do
      admin = admin!()
      user = user!()

      assert {:error, %Ash.Error.Forbidden{}} = User.set_admin(admin, false, actor: user)
      assert {:ok, %{admin: true}} = User.set_admin(user, true, actor: admin)
      assert {:ok, %{admin: false}} = User.set_admin(user, false, actor: admin)
    end

    test "the last admin cannot be removed, by an admin or the console" do
      admin = admin!()

      assert {:error, %Ash.Error.Invalid{} = error} = User.set_admin(admin, false, actor: admin)
      assert Exception.message(error) =~ "the last admin cannot be removed"
      assert {:error, _error} = User.set_admin(admin, false)
      assert Ash.get!(User, admin.id).admin

      other = admin!()
      assert {:ok, %{admin: false}} = User.set_admin(admin, false, actor: other)
    end
  end

  describe "policies" do
    test "signed-in users can read users" do
      user = user!()

      assert {:ok, [_ | _]} = Ash.read(User, actor: user)
      assert {:ok, []} = Ash.read(User, actor: nil, authorize?: true)
    end
  end

  describe "Release.update_admin/3" do
    test "grants and revokes by login, case-insensitively, but keeps the last admin" do
      only = admin!(%{login: "only"})
      user = user!(%{login: "Octocat"})

      assert Release.update_admin(:github, "octocat", true) == {:ok, "Octocat is now an admin."}
      assert Ash.get!(User, user.id).admin

      assert Release.update_admin(:github, "OCTOCAT", false) ==
               {:ok, "Octocat is no longer an admin."}

      refute Ash.get!(User, user.id).admin

      assert {:error, message} = Release.update_admin(:github, "only", false)
      assert message =~ "the last admin cannot be removed"
      assert Ash.get!(User, only.id).admin
    end

    test "reports unknown and ambiguous logins" do
      admin!()

      assert {:error, "no user \"nobody\" has signed in yet"} =
               Release.update_admin(:github, "nobody", true)

      user!(%{login: "twin", external_id: "100"})
      user!(%{login: "Twin", external_id: "200"})
      assert {:error, message} = Release.update_admin(:github, "twin", true)
      assert message =~ "several users (100, 200)" or message =~ "several users (200, 100)"
    end
  end
end
