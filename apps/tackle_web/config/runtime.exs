import Config

config :tackle_web,
  review_jail: System.get_env("TACKLE_WEB_REVIEW_JAIL"),
  state_dir: System.get_env("TACKLE_WEB_STATE_DIR", "/var/lib/tackle-web")

# Production settings from the environment. The NixOS module sets them; the
# secrets (SECRET_KEY_BASE, TACKLE_WEB_CLOAK_KEY, a DATABASE_URL with a
# password) come from its environment file. Forge and provider secrets are
# not configured here: they are entered in the app and stored encrypted.
if config_env() == :prod do
  fetch! = fn name ->
    System.get_env(name) ||
      raise "environment variable #{name} is missing; see apps/tackle_web/README.md"
  end

  # Either a DATABASE_URL, or (the default) a local server over its Unix
  # socket with peer authentication, so no password is needed.
  repo =
    case System.get_env("DATABASE_URL") do
      nil ->
        [
          socket_dir: System.get_env("TACKLE_WEB_DATABASE_SOCKET_DIR", "/run/postgresql"),
          database: System.get_env("TACKLE_WEB_DATABASE", "tackle_web"),
          username: System.get_env("TACKLE_WEB_DATABASE_USER", "tackle-web")
        ]

      url ->
        [url: url]
    end

  config :tackle_web,
         Tackle.Web.Repo,
         repo ++ [pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))]

  listen_address =
    case :inet.parse_address(String.to_charlist(System.get_env("LISTEN_ADDRESS", "127.0.0.1"))) do
      {:ok, address} -> address
      {:error, _reason} -> raise "LISTEN_ADDRESS is not an IP address"
    end

  # The public URL, as the forge and browsers reach the app (behind a
  # reverse proxy, the proxy's URL).
  public_url =
    case URI.parse(System.get_env("TACKLE_WEB_URL", "http://localhost:4000")) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        uri

      _invalid ->
        raise "TACKLE_WEB_URL must be an http:// or https:// URL with a host"
    end

  config :tackle_web, Tackle.Web.Endpoint,
    server: true,
    http: [ip: listen_address, port: String.to_integer(System.get_env("PORT", "4000"))],
    url: [host: public_url.host, port: public_url.port, scheme: public_url.scheme],
    secret_key_base: fetch!.("SECRET_KEY_BASE")

  # Behind a TLS-terminating reverse proxy (an https TACKLE_WEB_URL): redirect
  # plain HTTP to HTTPS, send HSTS, and keep the session cookie to HTTPS. The
  # proxy must set X-Forwarded-Proto (and overwrite one from the client).
  # Health checks, and requests to the loopback addresses, stay on HTTP.
  if public_url.scheme == "https" do
    https_host =
      if public_url.port == 443,
        do: public_url.host,
        else: "#{public_url.host}:#{public_url.port}"

    config :tackle_web,
      secure_cookies: true,
      force_ssl: [
        rewrite_on: [:x_forwarded_proto],
        hsts: true,
        host: https_host,
        exclude: [hosts: ["localhost", "127.0.0.1"], paths: ["/health"]]
      ]
  end

  # The current key encrypts; retired keys (comma-separated) only decrypt
  # what was written before a rotation. See Tackle.Web.Vault.
  config :tackle_web, Tackle.Web.Vault,
    key: fetch!.("TACKLE_WEB_CLOAK_KEY"),
    retired_keys:
      "TACKLE_WEB_CLOAK_RETIRED_KEYS"
      |> System.get_env("")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
end
