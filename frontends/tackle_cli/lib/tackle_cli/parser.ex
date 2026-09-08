defmodule Tackle.CLI.Parser do
  @moduledoc false

  @type command ::
          {:run, %{model: String.t() | nil, prompt: String.t() | nil}}
          | {:models, %{}}
          | {:auth_login, %{provider: String.t()}}
          | {:auth_status, %{provider: String.t() | nil}}
          | {:auth_logout, %{provider: String.t()}}

  @type parse_result ::
          {:ok, command()}
          | {:help, String.t()}
          | {:version, String.t()}
          | {:error, String.t()}

  @doc "Parses CLI arguments into frontend commands."
  @spec parse([String.t()]) :: parse_result()
  def parse(argv) when is_list(argv) do
    parser = parser()

    case Optimus.parse(parser, argv) do
      {:ok, result} ->
        {:ok, run_command(result)}

      {:ok, [:run], result} ->
        {:ok, run_command(result)}

      {:ok, [:models], _result} ->
        {:ok, {:models, %{}}}

      {:ok, [:auth, :login], result} ->
        {:ok, {:auth_login, %{provider: result.args.provider}}}

      {:ok, [:auth, :status], result} ->
        {:ok, {:auth_status, %{provider: Map.get(result.args, :provider)}}}

      {:ok, [:auth, :logout], result} ->
        {:ok, {:auth_logout, %{provider: result.args.provider}}}

      {:error, errors} ->
        {:error, format_errors(parser, errors)}

      {:error, subcommand_path, errors} ->
        {:error, format_errors(parser, subcommand_path, errors)}

      :help ->
        {:help, format_help(parser, [])}

      {:help, subcommand_path} ->
        {:help, format_help(parser, subcommand_path)}

      :version ->
        {:version, format_version(parser)}
    end
  end

  def parse(argv), do: {:error, "invalid argv: #{inspect(argv)}"}

  defp parser do
    Optimus.new!(
      name: "tackle",
      description: "Tackle developer harness",
      version: version(),
      about: "Frontend for configured Tackle harness sessions.",
      allow_unknown_args: false,
      parse_double_dash: true,
      options: [
        model: [
          value_name: "MODEL",
          long: "--model",
          short: "-m",
          help: "Canonical model reference selected from root harness adapters",
          parser: :string,
          global: true
        ]
      ],
      subcommands: [
        run: [
          name: "run",
          about: "Open the terminal frontend or submit one prompt",
          args: [
            prompt: [
              value_name: "PROMPT",
              help: "Optional one-shot prompt. Omit it to open the TUI.",
              required: false,
              parser: :string
            ]
          ]
        ],
        models: [
          name: "models",
          about: "List models exposed by root harness adapter loading"
        ],
        auth: [
          name: "auth",
          about: "Manage provider credentials",
          subcommands: [
            login: [
              name: "login",
              about: "Authenticate with a provider",
              args: [provider: provider_arg(required: true)]
            ],
            status: [
              name: "status",
              about: "Show provider credential status",
              args: [provider: provider_arg(required: false)]
            ],
            logout: [
              name: "logout",
              about: "Delete stored provider credentials",
              args: [provider: provider_arg(required: true)]
            ]
          ]
        ]
      ]
    )
  end

  defp provider_arg(opts) do
    [
      value_name: "PROVIDER",
      help: "Provider id such as openai-codex",
      required: Keyword.fetch!(opts, :required),
      parser: :string
    ]
  end

  defp run_command(result) do
    {:run,
     %{
       model: Map.get(result.options, :model),
       prompt: Map.get(result.args, :prompt)
     }}
  end

  defp format_errors(parser, errors) do
    parser
    |> Optimus.Errors.format(errors)
    |> lines_to_string()
  end

  defp format_errors(parser, subcommand_path, errors) do
    parser
    |> Optimus.Errors.format(subcommand_path, errors)
    |> lines_to_string()
  end

  defp format_help(parser, subcommand_path) do
    parser
    |> Optimus.Help.help(subcommand_path, terminal_columns())
    |> lines_to_string()
  end

  defp format_version(parser) do
    parser
    |> Optimus.Title.title()
    |> lines_to_string()
  end

  defp lines_to_string(lines) do
    lines
    |> Enum.map(&IO.iodata_to_binary/1)
    |> Enum.join("\n")
  end

  defp terminal_columns do
    case Optimus.Term.width() do
      {:ok, width} -> width
      _error -> 80
    end
  end

  defp version do
    case Application.spec(:tackle_cli, :vsn) do
      nil -> "0.1.0"
      version -> List.to_string(version)
    end
  end
end
