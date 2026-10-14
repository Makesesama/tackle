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
          | {:auth_login, login_options()}
          | {:auth_status, auth_options(String.t() | nil)}
          | {:auth_usage, auth_options(String.t() | nil)}
          | {:auth_logout, auth_options(String.t())}
          | {:mcp_list, %{}}
          | {:mcp_add, map()}
          | {:mcp_remove, String.t()}
          | {:mcp_login, %{name: String.t(), client_id: String.t() | nil}}
          | {:mcp_status, String.t() | nil}
          | {:mcp_logout, String.t()}
          | {:sdk, %{}}
          | {:review, review_options()}

  @type review_options :: %{
          model: String.t() | nil,
          thinking: String.t() | nil,
          range: String.t() | nil,
          staged: boolean(),
          profile: :quiet | :default | :assertive | nil,
          samples: pos_integer(),
          format: :text | :json,
          tuning: keyword()
        }

  @type auth_options(provider) :: %{
          provider: provider,
          format: :human | :plain | :json,
          color: :auto | :always | :never
        }

  @type login_options :: %{
          provider: String.t(),
          as: String.t() | nil,
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

  defp parse_result({:ok, [:mcp], _result}, parser),
    do: {:help, format_help(parser, [:mcp])}

  defp parse_result({:ok, [:mcp, :list], _result}, _parser), do: {:ok, {:mcp_list, %{}}}

  defp parse_result({:ok, [:mcp, :add], result}, _parser) do
    {:ok,
     {:mcp_add,
      %{
        name: result.args.name,
        stdio: Map.get(result.options, :stdio),
        http: Map.get(result.options, :http),
        args: Map.get(result.options, :arg, [])
      }}}
  end

  defp parse_result({:ok, [:mcp, :remove], result}, _parser),
    do: {:ok, {:mcp_remove, result.args.name}}

  defp parse_result({:ok, [:mcp, :auth], _result}, parser),
    do: {:help, format_help(parser, [:mcp, :auth])}

  defp parse_result({:ok, [:mcp, :auth, :login], result}, _parser),
    do:
      {:ok,
       {:mcp_login, %{name: result.args.name, client_id: Map.get(result.options, :client_id)}}}

  defp parse_result({:ok, [:mcp, :auth, :status], result}, _parser),
    do: {:ok, {:mcp_status, Map.get(result.args, :name)}}

  defp parse_result({:ok, [:mcp, :auth, :logout], result}, _parser),
    do: {:ok, {:mcp_logout, result.args.name}}

  defp parse_result({:ok, [:sdk], _result}, _parser), do: {:ok, {:sdk, %{}}}

  # RANGE is optional, so Optimus hands `--help` and unknown options to it.
  # A Git revision never starts with `-`.
  defp parse_result({:ok, [:review], %{args: %{range: help}}}, parser)
       when help in ["--help", "-h"],
       do: {:help, format_help(parser, [:review])}

  defp parse_result({:ok, [:review], %{args: %{range: "-" <> _ = range}}}, _parser),
    do: {:error, "unrecognized argument: #{inspect(range)}; see `tackle help review`"}

  defp parse_result({:ok, [:review], result}, _parser) do
    range = Map.get(result.args, :range)
    staged = Map.get(result.flags, :staged, false) == true

    if staged and range != nil do
      {:error, "--staged cannot be combined with a RANGE"}
    else
      {:ok,
       {:review,
        %{
          model: Map.get(result.options, :model),
          thinking: Map.get(result.options, :thinking),
          range: range,
          staged: staged,
          profile: Map.get(result.options, :profile),
          samples: Map.get(result.options, :samples, 1),
          format: Map.get(result.options, :format, :text),
          tuning: review_tuning(result)
        }}}
    end
  end

  defp parse_result({:ok, [:auth], _result}, parser),
    do: {:help, format_help(parser, [:auth])}

  defp parse_result({:ok, [:auth, :login], result}, _parser),
    do:
      {:ok,
       {:auth_login,
        result
        |> auth_command(result.args.provider)
        |> Map.put(:as, Map.get(result.options, :as))}}

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
          help: "Canonical model reference provider/model, such as openai-codex/gpt-5.5",
          parser: :string,
          global: true
        ],
        thinking: [
          value_name: "LEVEL",
          long: "--thinking",
          help: "Thinking level: off, minimal, low, medium, high, xhigh, or max",
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
          about: "List models of the configured providers"
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
        mcp: [
          name: "mcp",
          about: "Manage MCP servers and OAuth connections",
          subcommands: [
            list: [name: "list", about: "List configured MCP servers"],
            add: [
              name: "add",
              about: "Add a server definition",
              args: [name: [value_name: "NAME", required: true, parser: :string]],
              options: [
                stdio: [long: "--stdio", value_name: "COMMAND", parser: :string],
                http: [long: "--http", value_name: "URL", parser: :string],
                arg: [long: "--arg", value_name: "ARG", parser: :string, multiple: true]
              ]
            ],
            remove: [
              name: "remove",
              about: "Remove a server definition",
              args: [name: [value_name: "NAME", required: true, parser: :string]]
            ],
            auth: [
              name: "auth",
              about: "Manage MCP OAuth credentials",
              subcommands: [
                login: [
                  name: "login",
                  about: "Authorize an HTTP server",
                  args: [name: [value_name: "NAME", required: true, parser: :string]],
                  options: [client_id: [long: "--client-id", value_name: "ID", parser: :string]]
                ],
                status: [
                  name: "status",
                  about: "Show OAuth status",
                  args: [name: [value_name: "NAME", required: false, parser: :string]]
                ],
                logout: [
                  name: "logout",
                  about: "Delete stored MCP credentials",
                  args: [name: [value_name: "NAME", required: true, parser: :string]]
                ]
              ]
            ]
          ]
        ],
        sdk: [
          name: "sdk",
          about: "Serve the JSON-RPC stdio SDK protocol for non-BEAM clients"
        ],
        review: [
          name: "review",
          about:
            "Review a change (experimental). Exits 1 when blocking findings are shown, " <>
              "2 when the review fails.",
          args: [
            range: [
              value_name: "RANGE",
              help:
                "base..head, base...head, or one revision compared with the working tree " <>
                  "(default: the branch since the default branch, including uncommitted changes)",
              required: false,
              parser: :string
            ]
          ],
          flags: [
            staged: [long: "--staged", help: "Review the index against HEAD"],
            no_pack_files: [
              long: "--no-pack-files",
              help: "Review each file's units in their own detector runs"
            ]
          ],
          options: [
            profile: [
              value_name: "PROFILE",
              long: "--profile",
              help:
                "Which findings to show: quiet, default, or assertive " <>
                  "(default: config.json's review.profile, else default)",
              parser: &review_profile/1
            ],
            samples: [
              value_name: "N",
              long: "--samples",
              help: "Detector runs per unit",
              parser: &positive_integer/1,
              default: 1
            ],
            format: [
              value_name: "FORMAT",
              long: "--format",
              help: "Output format: text or json",
              parser: &review_format/1,
              default: :text
            ],
            unit_lines: [
              value_name: "N",
              long: "--unit-lines",
              help:
                "Changed lines per detector run (default 150); smaller is more focused but costlier",
              parser: &positive_integer/1
            ],
            verify_batch: [
              value_name: "N",
              long: "--verify-batch",
              help: "Candidates of one unit verified per verifier run (default 4)",
              parser: &positive_integer/1
            ],
            verify_limit: [
              value_name: "N",
              long: "--verify-limit",
              help: "Most candidates to verify, best first (default: twice the profile's cap)",
              parser: &positive_integer/1
            ],
            score_batch: [
              value_name: "N",
              long: "--score-batch",
              help: "Findings scored per scorer call (default 10)",
              parser: &positive_integer/1
            ],
            stage_thinking: [
              value_name: "STAGE=LEVEL,...",
              long: "--stage-thinking",
              help:
                "Thinking levels of review stages (detector, verifier, scorer), such as " <>
                  "detector=medium,verifier=low; others use config.json's review.thinking, " <>
                  "then the session's level",
              parser: &stage_thinking/1
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
              about: "Authenticate with a provider, or add a named account with --as",
              args: [
                provider: [
                  value_name: "PROVIDER",
                  help:
                    "Provider id such as openai-codex or ollama-cloud; with --as, " <>
                      "also an adapter type id",
                  required: true,
                  parser: :string
                ]
              ],
              options: [
                as: [
                  value_name: "NAME",
                  long: "--as",
                  help:
                    "Log in as a new provider NAME on the same adapter, such as codex-work; " <>
                      "its models are selected as NAME/model",
                  parser: :string
                ]
              ]
            ],
            status: [
              name: "status",
              about: "Show credential status of one provider, or list every provider",
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

  @review_profiles %{"quiet" => :quiet, "default" => :default, "assertive" => :assertive}

  defp review_profile(value) do
    case Map.fetch(@review_profiles, value) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:error, "must be quiet, default, or assertive"}
    end
  end

  # Cost/quality settings passed to `Tackle.Review.run/2` only when given,
  # so the review's own defaults apply otherwise.
  defp review_tuning(result) do
    units =
      [max_changed_lines: Map.get(result.options, :unit_lines)]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> then(fn units ->
        if Map.get(result.flags, :no_pack_files) == true,
          do: units ++ [pack_files: false],
          else: units
      end)

    [
      units: if(units == [], do: nil, else: units),
      verify_batch: Map.get(result.options, :verify_batch),
      verify_limit: Map.get(result.options, :verify_limit),
      score_batch: Map.get(result.options, :score_batch),
      thinking: Map.get(result.options, :stage_thinking)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  @review_stages %{"detector" => :detector, "verifier" => :verifier, "scorer" => :scorer}

  defp stage_thinking(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      with [stage, level] <- entry |> String.split("=", parts: 2) |> Enum.map(&String.trim/1),
           {:ok, stage} <- Map.fetch(@review_stages, stage),
           :ok <- Tackle.Thinking.validate(level) do
        {:cont, {:ok, acc ++ [{stage, level}]}}
      else
        _invalid ->
          {:halt,
           {:error,
            "must be STAGE=LEVEL pairs with stages detector, verifier, or scorer and levels " <>
              Enum.join(Tackle.Thinking.levels(), ", ")}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, "must name at least one STAGE=LEVEL pair"}
      result -> result
    end
  end

  defp review_format("text"), do: {:ok, :text}
  defp review_format("json"), do: {:ok, :json}
  defp review_format(_value), do: {:error, "must be text or json"}

  defp positive_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _other -> {:error, "must be a positive integer"}
    end
  end

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
      help: "Provider id such as openai-codex, deepseek, or codex-work",
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

  # Fallback for a call made before the application is loaded; a release always
  # carries its own version.
  defp version do
    case Application.spec(:tackle_cli, :vsn) do
      nil -> "unknown"
      version -> List.to_string(version)
    end
  end
end
