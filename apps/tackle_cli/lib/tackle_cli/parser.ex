defmodule Tackle.CLI.Parser do
  @moduledoc false

  @type command ::
          {:run,
           %{
             model: String.t() | nil,
             thinking: String.t() | nil,
             prompt: String.t() | nil,
             resume: String.t() | :latest | nil,
             abandon: boolean()
           }}
          | {:sessions,
             %{
               query: String.t() | nil,
               limit: pos_integer() | nil,
               cursor: String.t() | nil,
               format: :human | :plain | :json,
               color: :auto | :always | :never
             }}
          | {:models, %{}}
          | {:auth_login, auth_options(String.t())}
          | {:auth_status, auth_options(String.t() | nil)}
          | {:auth_usage, auth_options(String.t() | nil)}
          | {:auth_logout, auth_options(String.t())}

  @type auth_options(provider) :: %{
          provider: provider,
          format: :human | :plain | :json,
          color: :auto | :always | :never
        }

  @type parse_result ::
          {:ok, command()}
          | {:help, String.t()}
          | {:version, String.t()}
          | {:error, String.t()}

  @doc "Parses CLI arguments into frontend commands."
  @spec parse([String.t()]) :: parse_result()
  def parse(argv) when is_list(argv) do
    parser = parser()
    argv = normalize_resume(argv)

    parser
    |> Optimus.parse(argv)
    |> parse_result(parser)
  end

  def parse(argv), do: {:error, "invalid argv: #{inspect(argv)}"}

  # An Optimus option cannot take an optional value, so a valueless `--resume`
  # is rewritten to the hidden `--resume-latest` flag before parsing. A value
  # is consumed as the session id only when it is not itself a flag, and `--`
  # still ends option parsing for the rest of the command line.
  defp normalize_resume(["--" | _rest] = argv), do: argv

  defp normalize_resume(["--resume" | rest]) do
    case rest do
      [value | tail] ->
        if resume_value?(value),
          do: ["--resume", value | normalize_resume(tail)],
          else: ["--resume-latest" | normalize_resume(rest)]

      [] ->
        ["--resume-latest"]
    end
  end

  defp normalize_resume([token | rest]), do: [token | normalize_resume(rest)]
  defp normalize_resume([]), do: []

  defp resume_value?("--"), do: false
  defp resume_value?("-" <> _rest), do: false
  defp resume_value?(_value), do: true

  defp parse_result({:ok, result}, _parser), do: {:ok, run_command(result)}
  defp parse_result({:ok, [:run], result}, _parser), do: {:ok, run_command(result)}
  defp parse_result({:ok, [:models], _result}, _parser), do: {:ok, {:models, %{}}}

  defp parse_result({:ok, [:sessions], result}, _parser) do
    {:ok,
     {:sessions,
      %{
        query: Map.get(result.options, :query),
        limit: Map.get(result.options, :limit),
        cursor: Map.get(result.options, :cursor),
        format: Map.get(result.options, :format, :human),
        color: Map.get(result.options, :color, :auto)
      }}}
  end

  defp parse_result({:ok, [:auth], _result}, parser),
    do: {:help, format_help(parser, [:auth])}

  defp parse_result({:ok, [:auth, :login], result}, _parser),
    do: {:ok, {:auth_login, auth_command(result, result.args.provider)}}

  defp parse_result({:ok, [:auth, :status], result}, _parser),
    do: {:ok, {:auth_status, auth_command(result, Map.get(result.args, :provider))}}

  defp parse_result({:ok, [:auth, :usage], result}, _parser),
    do: {:ok, {:auth_usage, auth_command(result, Map.get(result.args, :provider))}}

  defp parse_result({:ok, [:auth, :logout], result}, _parser),
    do: {:ok, {:auth_logout, auth_command(result, result.args.provider)}}

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
          help: "Resume a durable session; omit the id to resume the most recent one",
          parser: :string,
          global: true
        ]
      ],
      flags: [
        abandon: [
          long: "--abandon",
          help: "Record turn.abandoned for an interrupted resumed session",
          global: true
        ],
        # Rewrite target for a valueless `--resume`; never documented.
        resume_latest: [
          long: "--resume-latest",
          hide: true,
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
              help: "Maximum number of results (default: 20)",
              parser: :integer
            ],
            cursor: [
              value_name: "CURSOR",
              long: "--cursor",
              help: "Continue from a cursor returned by JSON output",
              parser: :string
            ],
            format: [
              value_name: "FORMAT",
              long: "--format",
              help: "Output format: human, plain, or json",
              parser: &output_format/1,
              default: :human
            ],
            color: [
              value_name: "WHEN",
              long: "--color",
              help: "Color output: auto, always, or never",
              parser: &color_mode/1,
              default: :auto
            ]
          ]
        ],
        auth: [
          name: "auth",
          about: "Manage provider credentials",
          options: output_options(global: true),
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
            usage: [
              name: "usage",
              about: "Show provider account usage",
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

  defp output_options(opts) do
    global? = Keyword.get(opts, :global, false)

    [
      format: [
        value_name: "FORMAT",
        long: "--format",
        help: "Output format: human, plain, or json",
        parser: &output_format/1,
        default: :human,
        global: global?
      ],
      color: [
        value_name: "WHEN",
        long: "--color",
        help: "Color output: auto, always, or never",
        parser: &color_mode/1,
        default: :auto,
        global: global?
      ]
    ]
  end

  defp output_format(value) when value in ["human", "plain", "json"],
    do: {:ok, String.to_existing_atom(value)}

  defp output_format(_value), do: {:error, "must be human, plain, or json"}

  defp color_mode(value) when value in ["auto", "always", "never"],
    do: {:ok, String.to_existing_atom(value)}

  defp color_mode(_value), do: {:error, "must be auto, always, or never"}

  defp auth_command(result, provider) do
    %{
      provider: provider,
      format: Map.get(result.options, :format, :human),
      color: Map.get(result.options, :color, :auto)
    }
  end

  defp provider_arg(opts) do
    [
      value_name: "PROVIDER",
      help: "Adapter id such as openai-codex or deepseek",
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
       resume: resume(result),
       abandon: Map.get(result.flags, :abandon, false) == true
     }}
  end

  # An explicit session id wins over the rewrite of a valueless `--resume`.
  defp resume(result) do
    case Map.get(result.options, :resume) do
      nil -> if Map.get(result.flags, :resume_latest, false), do: :latest, else: nil
      session_id -> session_id
    end
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
