defmodule Tackle.CLI.Parser do
  @moduledoc false

  @type command ::
          {:run,
           %{
             model: String.t() | nil,
             thinking: String.t() | nil,
             prompt: String.t() | nil,
             resume: String.t() | nil,
             abandon: boolean()
           }}
          | {:sessions, %{query: String.t() | nil, limit: pos_integer() | nil}}
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

    parser
    |> Optimus.parse(argv)
    |> parse_result(parser)
  end

  def parse(argv), do: {:error, "invalid argv: #{inspect(argv)}"}

  defp parse_result({:ok, result}, _parser), do: {:ok, run_command(result)}
  defp parse_result({:ok, [:run], result}, _parser), do: {:ok, run_command(result)}
  defp parse_result({:ok, [:models], _result}, _parser), do: {:ok, {:models, %{}}}

  defp parse_result({:ok, [:sessions], result}, _parser) do
    {:ok,
     {:sessions,
      %{query: Map.get(result.options, :query), limit: Map.get(result.options, :limit)}}}
  end

  defp parse_result({:ok, [:auth], _result}, parser),
    do: {:help, format_help(parser, [:auth])}

  defp parse_result({:ok, [:auth, :login], result}, _parser),
    do: {:ok, {:auth_login, %{provider: result.args.provider}}}

  defp parse_result({:ok, [:auth, :status], result}, _parser),
    do: {:ok, {:auth_status, %{provider: Map.get(result.args, :provider)}}}

  defp parse_result({:ok, [:auth, :logout], result}, _parser),
    do: {:ok, {:auth_logout, %{provider: result.args.provider}}}

  defp parse_result({:error, errors}, parser),
    do: {:error, format_errors(parser, errors)}

  defp parse_result({:error, subcommand_path, errors}, parser),
    do: {:error, format_errors(parser, subcommand_path, errors)}

  defp parse_result(:help, parser), do: {:help, format_help(parser, [])}

  defp parse_result({:help, subcommand_path}, parser),
    do: {:help, format_help(parser, subcommand_path)}

  defp parse_result(:version, parser), do: {:version, format_version(parser)}

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
        ],
        thinking: [
          value_name: "LEVEL",
          long: "--thinking",
          help: "Thinking level: off, minimal, low, medium, high, or xhigh",
          parser: :string,
          global: true
        ],
        resume: [
          value_name: "SESSION_ID",
          long: "--resume",
          help: "Resume a durable session by id instead of starting a new one",
          parser: :string,
          global: true
        ]
      ],
      flags: [
        abandon: [
          long: "--abandon",
          help: "Record turn.abandoned for an interrupted resumed session",
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
        sessions: [
          name: "sessions",
          about: "List or search durable sessions",
          options: [
            query: [
              value_name: "TEXT",
              long: "--query",
              help: "Full-text query over indexed session fields",
              parser: :string
            ],
            limit: [
              value_name: "N",
              long: "--limit",
              help: "Maximum number of results",
              parser: :integer
            ]
          ]
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
       thinking: Map.get(result.options, :thinking),
       prompt: Map.get(result.args, :prompt),
       resume: Map.get(result.options, :resume),
       abandon: Map.get(result.flags, :abandon, false) == true
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

  defp lines_to_string(lines), do: Enum.map_join(lines, "\n", &IO.iodata_to_binary/1)

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
