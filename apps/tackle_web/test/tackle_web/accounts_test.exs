defmodule Tackle.Web.AccountsTest do
  use Tackle.Web.DataCase, async: false

  import Tackle.Web.AccountsFixtures

  alias Tackle.Web.Accounts.User
  alias Tackle.Web.Release

  defp sign_in!(external_id, login, name \\ nil) do
    User.sign_in!(%{forge: :github, external_id: external_id, login: login, name: name})
  end

  describe "sign_in" do
    test "makes the first user an admin and nobody after" do
      first = sign_in!("1", "ada")
      second = sign_in!("2", "grace")

      assert first.admin
      refute second.admin
      assert first.last_signed_in_at
    end

    test "updates login and name on a later sign-in, but never the admin flag" do
      sign_in!("1", "ada")
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

  describe "policies" do
    test "signed-in users can read users; nobody can change them through an actor" do
      admin = admin!()
      user = user!()

      assert {:ok, [_ | _]} = Ash.read(User, actor: user)
      assert {:ok, []} = Ash.read(User, actor: nil, authorize?: true)

      assert {:error, %Ash.Error.Forbidden{}} = User.set_admin(user, true, actor: admin)
      refute Ash.get!(User, user.id).admin
    end
  end

  describe "Release.update_admin/3" do
    test "grants and revokes by login, case-insensitively" do
      admin!()
      user = user!(%{login: "Octocat"})

      assert Release.update_admin(:github, "octocat", true) == {:ok, "Octocat is now an admin."}
      assert Ash.get!(User, user.id).admin

      assert Release.update_admin(:github, "OCTOCAT", false) ==
               {:ok, "Octocat is no longer an admin."}

      refute Ash.get!(User, user.id).admin
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
