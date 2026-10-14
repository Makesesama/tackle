defmodule Tackle.CLI.MCPLoginTest do
  use ExUnit.Case, async: false

  alias Tackle.CLI.MCP
  alias Tackle.CLI.MCP.Config

  describe "redirect_target/1" do
    test "defaults to a random loopback port with the /callback path" do
      assert {:ok, %{uri: nil, ip: {127, 0, 0, 1}, family: :inet, port: 0, path: "/callback"}} =
               MCP.redirect_target(nil)
    end

    test "accepts exact loopback callbacks" do
      assert {:ok, %{uri: "http://localhost:8080/callback", port: 8080, path: "/callback"}} =
               MCP.redirect_target("http://localhost:8080/callback")

      assert {:ok, %{ip: {127, 0, 0, 1}, port: 33_418, path: "/"}} =
               MCP.redirect_target("http://127.0.0.1:33418/")

      assert {:ok, %{path: "/"}} = MCP.redirect_target("http://127.0.0.1:33418")

      assert {:ok, %{family: :inet6, ip: {0, 0, 0, 0, 0, 0, 0, 1}, port: 9000}} =
               MCP.redirect_target("http://[::1]:9000/cb")
    end

    test "rejects non-loopback, https, query, and fragment callbacks" do
      for uri <- [
            "https://localhost:8080/callback",
            "http://example.com:8080/callback",
            "http://localhost:8080/callback?x=1",
            "http://localhost:8080/callback#x",
            "http://user@localhost:8080/callback",
            "localhost:8080/callback"
          ] do
        assert {:error, :invalid_redirect_uri} = MCP.redirect_target(uri), uri
      end
    end
  end

  describe "login with a pre-registered client" do
    setup do
      home =
        Path.join(System.tmp_dir!(), "tackle-mcp-login-#{System.unique_integer([:positive])}")

      previous_home = System.get_env("TACKLE_HOME")
      previous_secret = System.get_env("TACKLE_MCP_CLIENT_SECRET")
      System.put_env("TACKLE_HOME", home)
      System.delete_env("TACKLE_MCP_CLIENT_SECRET")

      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

      {:ok, {_, port}} = :inet.sockname(listener)
      parent = self()
      server = spawn_link(fn -> serve(listener, "http://127.0.0.1:#{port}", parent) end)
      name = "registered#{System.unique_integer([:positive])}"
      url = "http://127.0.0.1:#{port}/mcp"
      :ok = Config.put(name, %{"transport" => "http", "url" => url})

      on_exit(fn ->
        :gen_tcp.close(listener)
        Process.exit(server, :kill)
        restore_env("TACKLE_HOME", previous_home)
        restore_env("TACKLE_MCP_CLIENT_SECRET", previous_secret)
        File.rm_rf!(home)
      end)

      {:ok, name: name, url: url}
    end

    test "uses the exact redirect URI, matches its callback path, and stores the secret", %{
      name: name,
      url: url
    } do
      redirect_port = free_port()
      redirect = "http://localhost:#{redirect_port}/oauth/done"
      {:ok, output} = StringIO.open("")

      task =
        Task.async(fn ->
          Process.group_leader(self(), output)

          MCP.login(%{
            name: name,
            client_id: "app",
            client_secret: "app-secret",
            redirect_uri: redirect
          })
        end)

      query = authorization_query(output)
      assert query["redirect_uri"] == redirect
      assert query["client_id"] == "app"
      refute Map.has_key?(query, "client_secret")

      assert callback(redirect_port, "/callback", query["state"]) =~ "400 Bad Request"
      assert callback(redirect_port, "/oauth/done", query["state"]) =~ "200 OK"
      assert Task.await(task) == 0

      assert_received {:token_request, body}
      params = URI.decode_query(body)
      assert params["redirect_uri"] == redirect
      assert params["client_id"] == "app"
      assert params["client_secret"] == "app-secret"
      refute_received {:registration_request, _}

      assert {:ok, %{"client_secret" => "app-secret", "resource" => ^url}} =
               Tackle.Auth.fetch(MCP.namespace(name))
    end
  end

  defp authorization_query(output, attempts \\ 200)

  defp authorization_query(_output, 0), do: flunk("login never printed an authorization URL")

  defp authorization_query(output, attempts) do
    {_input, printed} = StringIO.contents(output)

    case Regex.run(~r{(http://\S+/authorize\?\S+)}, printed) do
      [_, url] ->
        url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      nil ->
        Process.sleep(10)
        authorization_query(output, attempts - 1)
    end
  end

  defp callback(port, path, state) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    query = URI.encode_query(%{"state" => state, "code" => "code"})
    :ok = :gen_tcp.send(socket, "GET #{path}?#{query} HTTP/1.1\r\nHost: localhost\r\n\r\n")
    {:ok, response} = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)
    response
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, {_, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
  end

  # Minimal authorization server without a registration endpoint, mirroring
  # providers such as Asana's V2 MCP server.
  defp serve(listener, base, parent) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {method, path, body} = read_request(socket)
        respond(socket, route(method, path, body, base, parent))
        serve(listener, base, parent)

      {:error, _} ->
        :ok
    end
  end

  defp route("GET", "/mcp", _body, _base, _parent), do: {401, ""}

  defp route("GET", "/.well-known/oauth-protected-resource/mcp", _body, base, _parent),
    do: {200, JSON.encode!(%{"authorization_servers" => [base]})}

  defp route("GET", "/.well-known/oauth-authorization-server", _body, base, _parent) do
    {200,
     JSON.encode!(%{
       "authorization_endpoint" => base <> "/authorize",
       "token_endpoint" => base <> "/token"
     })}
  end

  defp route("POST", "/token", body, _base, parent) do
    send(parent, {:token_request, body})

    {200,
     JSON.encode!(%{
       "access_token" => "token",
       "token_type" => "Bearer",
       "refresh_token" => "refresh",
       "expires_in" => 3600
     })}
  end

  defp route("POST", "/register", body, _base, parent) do
    send(parent, {:registration_request, body})
    {404, ""}
  end

  defp route(_method, _path, _body, _base, _parent), do: {404, ""}

  defp read_request(socket, buffer \\ "") do
    {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
    buffer = buffer <> data

    case String.split(buffer, "\r\n\r\n", parts: 2) do
      [head, body] ->
        [request_line | headers] = String.split(head, "\r\n")
        [method, target | _] = String.split(request_line, " ")
        length = content_length(headers)
        {method, URI.parse(target).path, read_body(socket, body, length)}

      [_] ->
        read_request(socket, buffer)
    end
  end

  defp content_length(headers) do
    Enum.find_value(headers, 0, fn header ->
      case String.split(header, ":", parts: 2) do
        [key, value] ->
          if String.downcase(key) == "content-length",
            do: value |> String.trim() |> String.to_integer()

        _ ->
          nil
      end
    end)
  end

  defp read_body(_socket, body, length) when byte_size(body) >= length, do: body

  defp read_body(socket, body, length) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
    read_body(socket, body <> data, length)
  end

  defp respond(socket, {status, body}) do
    :gen_tcp.send(
      socket,
      "HTTP/1.1 #{status} X\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
    )

    :gen_tcp.close(socket)
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
