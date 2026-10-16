defmodule Tackle.Web.ReleaseTest do
  use ExUnit.Case, async: true

  alias Tackle.Web.Release

  @moduletag :tmp_dir

  test "reads the GitHub App's ids from the environment and its secrets from files", %{
    tmp_dir: dir
  } do
    key =
      write(
        dir,
        "key.pem",
        "-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----\n"
      )

    secret = write(dir, "webhook", "s3cret\n")

    env = %{
      "TACKLE_WEB_GITHUB_APP_ID" => " 4242 ",
      "TACKLE_WEB_GITHUB_PRIVATE_KEY_FILE" => key,
      "TACKLE_WEB_GITHUB_WEBHOOK_SECRET_FILE" => secret
    }

    assert {:ok, params} = Release.github_app_params(env)
    assert params.app_id == "4242"
    assert params.webhook_secret == "s3cret"
    assert params.private_key =~ "BEGIN RSA PRIVATE KEY"
    assert params.client_id == nil
    assert params.client_secret == nil
  end

  test "reads the optional client id and secret", %{tmp_dir: dir} do
    env = %{
      "TACKLE_WEB_GITHUB_APP_ID" => "1",
      "TACKLE_WEB_GITHUB_CLIENT_ID" => "Iv1.abc",
      "TACKLE_WEB_GITHUB_PRIVATE_KEY_FILE" => write(dir, "key", "k"),
      "TACKLE_WEB_GITHUB_WEBHOOK_SECRET_FILE" => write(dir, "webhook", "w"),
      "TACKLE_WEB_GITHUB_CLIENT_SECRET_FILE" => write(dir, "client", "c\n")
    }

    assert {:ok, %{client_id: "Iv1.abc", client_secret: "c"}} = Release.github_app_params(env)

    assert {:error, "TACKLE_WEB_GITHUB_WEBHOOK_SECRET_FILE is not set"} =
             Release.github_app_params(Map.delete(env, "TACKLE_WEB_GITHUB_WEBHOOK_SECRET_FILE"))
  end

  test "reports what is missing or unreadable", %{tmp_dir: dir} do
    empty = write(dir, "empty", "\n")

    assert {:error, "TACKLE_WEB_GITHUB_APP_ID is not set"} = Release.github_app_params(%{})

    assert {:error, "TACKLE_WEB_GITHUB_PRIVATE_KEY_FILE is not set"} =
             Release.github_app_params(%{"TACKLE_WEB_GITHUB_APP_ID" => "1"})

    assert {:error, "TACKLE_WEB_GITHUB_PRIVATE_KEY_FILE names an empty file"} =
             Release.github_app_params(%{
               "TACKLE_WEB_GITHUB_APP_ID" => "1",
               "TACKLE_WEB_GITHUB_PRIVATE_KEY_FILE" => empty
             })

    assert {:error, "TACKLE_WEB_GITHUB_PRIVATE_KEY_FILE: cannot read " <> _reason} =
             Release.github_app_params(%{
               "TACKLE_WEB_GITHUB_APP_ID" => "1",
               "TACKLE_WEB_GITHUB_PRIVATE_KEY_FILE" => Path.join(dir, "missing")
             })
  end

  defp write(dir, name, contents) do
    path = Path.join(dir, name)
    File.write!(path, contents)
    path
  end
end
