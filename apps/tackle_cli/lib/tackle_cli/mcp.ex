defmodule Tackle.CLI.MCP do
  @moduledoc false

  alias Tackle.CLI.MCP.Config
  alias Tackle.Plugins.MCP.OAuth

  def list do
    with {:ok, entries} <- entries() do
      Enum.each(entries, fn entry ->
        Owl.IO.puts(
          "#{entry.name}\t#{entry.definition["transport"]}\t#{target(entry)}\t#{scope_label(entry)}"
        )
      end)

      0
    else
      error -> fail(error)
    end
  end

  defp target(%{definition: %{"url" => url}}), do: url

  defp target(%{definition: %{"command" => command, "args" => args}}),
    do: Enum.map_join([command | args], " ", &quote_arg/1)

  defp quote_arg(arg) do
    if Regex.match?(~r/\A[A-Za-z0-9_@%+=:,.\/-]+\z/, arg), do: arg, else: inspect(arg)
  end

  defp scope_label(%{scope: :user}), do: "user"
  defp scope_label(%{scope: :project, approved: true}), do: "project"
  defp scope_label(%{scope: :project}), do: "project (not approved)"

  # All entries; a broken project layer is reported and the user layer listed.
  defp entries do
    with {:ok, entries, warning} <- Config.effective_or_user() do
      if warning, do: Owl.IO.puts(warning, :stderr)
      {:ok, entries}
    end
  end

  def add(%{name: name, stdio: command, http: url, args: args} = opts) do
    definition =
      cond do
        is_binary(command) and is_nil(url) ->
          %{"transport" => "stdio", "command" => command, "args" => args}

        is_binary(url) and is_nil(command) and args == [] ->
          %{"transport" => "http", "url" => url}

        true ->
          nil
      end

    if Map.get(opts, :project, false),
      do: add_project(name, definition),
      else: add_user(name, definition)
  end

  defp add_user(name, definition) do
    case Config.put(name, definition) do
      :ok ->
        Owl.IO.puts("Added MCP server #{name}")
        0

      error ->
        fail(error)
    end
  end

  # The user adding a project server has seen its definition, so it is approved.
  defp add_project(name, definition) do
    with {:ok, path} <- Config.put_project(name, definition),
         :ok <- Config.approve(path, name, definition) do
      Owl.IO.puts("Added project MCP server #{name} to #{path}")
      0
    else
      error -> fail(error)
    end
  end

  def remove(%{name: name, project: true}) do
    with {:ok, path} <- Config.remove_project(name),
         :ok <- Config.revoke(path, name),
         {:ok, _} <- ensure_started(),
         :ok <- Tackle.CLI.MCP.Connections.invalidate(name) do
      Owl.IO.puts("Removed project MCP server #{name} from #{path}")
      0
    else
      error -> fail(error)
    end
  end

  def remove(%{name: name}), do: remove(name)

  def remove(name) do
    with {:ok, _} <- ensure_started(),
         {:ok, servers} <- Config.list(),
         {:ok, _definition} <- fetch_server(servers, name),
         :ok <- Tackle.Auth.delete(namespace(name)),
         :ok <- Config.remove(name),
         :ok <- Tackle.CLI.MCP.Connections.invalidate(name) do
      Owl.IO.puts("Removed MCP server #{name}")
      0
    else
      error -> fail(error)
    end
  end

  @doc false
  # Approves the current project definition of NAME after showing it. Approval
  # is bound to the exact definition, so editing it requires approving again.
  # `confirm` is injectable for tests.
  def approve(name, confirm \\ &Owl.IO.confirm(message: &1)) do
    with {:ok, entries} <- Config.effective(),
         {:ok, entry} <- fetch_project_entry(entries, name),
         :ok <- confirm_approval(entry, confirm),
         :ok <- Config.approve(entry.path, name, entry.definition) do
      Owl.IO.puts("Approved project MCP server #{name}")
      0
    else
      error -> fail(error)
    end
  end

  defp confirm_approval(entry, confirm) do
    Owl.IO.puts("Project MCP server #{entry.name} from #{entry.path}:\n#{describe(entry)}")

    if confirm.("Approve it? Its command runs on your machine with your permissions."),
      do: :ok,
      else: {:error, :aborted}
  end

  defp fetch_project_entry(entries, name) do
    case Enum.find(entries, &(&1.name == name and &1.scope == :project)) do
      nil -> {:error, :mcp_project_server_missing}
      entry -> {:ok, entry}
    end
  end

  defp describe(%{definition: %{"transport" => "http"}} = entry), do: "  http #{target(entry)}"

  defp describe(%{spec: spec} = entry),
    do:
      "  #{target(entry)}\n  (runs in #{spec["cwd"]}; it may execute files from this repository)"

  # Servers that may connect: user servers and approved project servers.
  defp servers do
    with {:ok, entries} <- entries() do
      {:ok, for(entry <- entries, entry.approved, into: %{}, do: {entry.name, entry.spec})}
    end
  end

  def status(name) do
    with {:ok, _} <- ensure_started(),
         {:ok, servers} <- servers() do
      servers = if name, do: Map.take(servers, [name]), else: servers

      if name && servers == %{},
        do: fail({:error, :mcp_server_missing}),
        else: print_status(servers)
    else
      error -> fail(error)
    end
  end

  defp print_status(servers) do
    Enum.each(Enum.sort(servers), fn {name, definition} ->
      status =
        if definition["transport"] == "stdio" do
          "not applicable"
        else
          case Tackle.Auth.status(namespace(name)) do
            :stored -> "stored"
            :missing -> "missing"
            {:error, reason} -> "error: #{inspect(reason)}"
          end
        end

      Owl.IO.puts("#{name}\t#{status}")
    end)

    0
  end

  def logout(name) do
    with {:ok, _} <- ensure_started(),
         {:ok, servers} <- servers(),
         {:ok, _} <- fetch_server(servers, name),
         :ok <- Tackle.Auth.delete(namespace(name)),
         :ok <- Tackle.CLI.MCP.Connections.invalidate(name) do
      Owl.IO.puts("Removed MCP credentials for #{name}")
      0
    else
      error -> fail(error)
    end
  end

  @client_secret_env "TACKLE_MCP_CLIENT_SECRET"

  def login(%{name: name} = opts) do
    with {:ok, client} <- client_credentials(opts),
         {:ok, _} <- ensure_started(),
         {:ok, servers} <- servers(),
         {:ok, %{"transport" => "http", "url" => url}} <- fetch_server(servers, name),
         {:ok, listener} <-
           :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true]),
         result <- authorize(name, url, listener, client) do
      result
    else
      {:ok, _} -> fail({:error, :mcp_oauth_requires_http})
      error -> fail(error)
    end
  end

  # A pre-registered client may be confidential, so its secret comes from
  # `--client-secret` or, to keep it out of argv and shell history, the
  # environment. Without `--client-id` the flow uses dynamic registration, which
  # issues its own credentials, so an explicit secret there is a usage error.
  @doc false
  def client_credentials(opts) do
    client_id = blank_to_nil(Map.get(opts, :client_id))
    flag_secret = blank_to_nil(Map.get(opts, :client_secret))

    cond do
      is_nil(client_id) and not is_nil(flag_secret) ->
        {:error, :client_secret_requires_client_id}

      is_nil(client_id) ->
        {:ok, [client_id: nil, client_secret: nil]}

      true ->
        secret = flag_secret || blank_to_nil(System.get_env(@client_secret_env))
        {:ok, [client_id: client_id, client_secret: secret]}
    end
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp authorize(name, url, listener, client) do
    try do
      {:ok, {_ip, port}} = :inet.sockname(listener)
      redirect = "http://127.0.0.1:#{port}/callback"

      with {:ok, flow} <-
             OAuth.begin(
               url,
               [redirect_uri: redirect, finch_name: Tackle.CLI.MCP.Finch] ++ client
             ),
           :ok <- announce(flow.authorization_url),
           {:ok, state, code, socket} <- callback(listener, flow.state),
           result <- OAuth.complete(flow, state, code: code),
           :ok <- respond(socket, result),
           {:ok, credentials} <- result,
           :ok <- Tackle.Auth.put(namespace(name), persistable(credentials)),
           :ok <- Tackle.CLI.MCP.Connections.invalidate(name) do
        Owl.IO.puts("Authorized MCP server #{name}")
        0
      else
        error -> fail(error)
      end
    after
      :gen_tcp.close(listener)
    end
  end

  defp announce(url) do
    Owl.IO.puts(
      "Open this URL to authorize the MCP server:\n#{url}\nWaiting for browser callback (up to 2 minutes)..."
    )

    :ok
  end

  defp callback(listener, expected) do
    deadline = System.monotonic_time(:millisecond) + 120_000
    wait_callback(listener, expected, deadline)
  end

  defp wait_callback(listener, expected, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :oauth_callback_timeout}
    else
      case :gen_tcp.accept(listener, remaining) do
        {:ok, socket} ->
          case :gen_tcp.recv(socket, 0, min(5_000, remaining)) do
            {:ok, line} ->
              case Regex.run(~r/\AGET \/callback\?([^ ]+) HTTP\/1\.[01]\r\n/, line) do
                [_, query] ->
                  params = URI.decode_query(query)

                  case params do
                    %{"state" => ^expected, "code" => code} when code != "" ->
                      {:ok, expected, code, socket}

                    _ ->
                      respond(socket, {:error, :invalid_oauth_callback})
                      wait_callback(listener, expected, deadline)
                  end

                _ ->
                  respond(socket, {:error, :invalid_oauth_callback})
                  wait_callback(listener, expected, deadline)
              end

            _ ->
              :gen_tcp.close(socket)
              wait_callback(listener, expected, deadline)
          end

        error ->
          error
      end
    end
  end

  defp respond(socket, result) do
    {status, body} =
      case result do
        {:ok, _} -> {"200 OK", "Authorization complete. Return to your terminal."}
        _ -> {"400 Bad Request", "Authorization failed. Return to your terminal."}
      end

    :gen_tcp.send(
      socket,
      "HTTP/1.1 #{status}\r\nContent-Type: text/plain\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"
    )

    :gen_tcp.close(socket)
    :ok
  end

  defp persistable(credentials) do
    credentials |> Map.drop([:request]) |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp fetch_server(servers, name) do
    case Map.fetch(servers, name) do
      {:ok, definition} -> {:ok, definition}
      :error -> {:error, :mcp_server_missing}
    end
  end

  def namespace(name), do: "mcp:#{name}"

  # Standalone commands run inside the CLI application's start callback.
  # Starting that same application again there would block its own startup.
  defp ensure_started do
    if System.get_env("__BURRITO") do
      Application.ensure_all_started(:tackle_mcp)
    else
      Application.ensure_all_started(:tackle_cli)
    end
  end

  defp fail({:error, :client_registration_unavailable}) do
    Owl.IO.puts(
      "MCP error: the authorization server does not support (or rejected) dynamic client " <>
        "registration. Register an OAuth app with the provider, then retry with " <>
        "--client-id ID (and #{@client_secret_env} or --client-secret if it issued a secret).",
      :stderr
    )

    1
  end

  defp fail({:error, :client_secret_requires_client_id}) do
    Owl.IO.puts("MCP error: --client-secret requires --client-id", :stderr)
    1
  end

  defp fail(reason) do
    Owl.IO.puts("MCP error: #{inspect(reason)}", :stderr)
    1
  end
end
