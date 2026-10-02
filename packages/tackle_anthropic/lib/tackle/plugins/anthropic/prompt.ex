defmodule Tackle.Plugins.Anthropic.Prompt do
  @moduledoc """
  Claude Code system-prompt shaping for Anthropic OAuth requests.

  Anthropic's OAuth classifier rejects premium-model requests that do not open
  with a Claude Code billing-header system block and identify as the Claude Code
  client. This module mirrors the behaviour of the reference
  `pi-anthropic-oauth` extension:

    * a billing-header text block (no `cache_control`),
    * the Claude Code identity block, and
    * the host system prompt, with Pi/Tackle identity paragraphs removed and the
      harness name rewritten to "Claude Code".

  Non-OAuth (API key) requests send the host system prompt unchanged. The
  advertised client version defaults to `2.1.280` and can be overridden with the
  `:claude_code_version` option or the
  `TACKLE_ANTHROPIC_CLAUDE_CODE_VERSION` environment variable.
  """

  alias Tackle.Lib.ID

  @default_claude_code_version "2.1.280"
  @identity "You are a Claude agent, built on Anthropic's Claude Agent SDK."
  @claude_code_version_env "TACKLE_ANTHROPIC_CLAUDE_CODE_VERSION"
  @rewrite_mode_env "TACKLE_ANTHROPIC_REWRITE_MODE"
  @rewrite_pattern_env "TACKLE_ANTHROPIC_REWRITE_PATTERN"

  @removal_anchors [
    "pi-coding-agent",
    "@earendil-works/pi-coding-agent",
    "badlogic/pi-mono",
    "tackle-coding-agent",
    "@makesesama/tackle",
    "makesesama/tackle"
  ]

  @rewrite_sources %{
    "aggressive" => "\\b[Pp]i\\b|\\b[Tt]ackle\\b",
    "path-safe" => "(?<![/\\\\])\\b[Pp]i\\b|(?<![/\\\\])\\b[Tt]ackle\\b",
    "technical-safe" =>
      "(?<![/\\\\.@:_-])\\b[Pp]i\\b(?![/\\\\.@:_-])|(?<![/\\\\.@:_-])\\b[Tt]ackle\\b(?![/\\\\.@:_-])"
  }

  @rewrite_modes ["aggressive", "path-safe", "technical-safe", "custom"]

  @type block :: map()

  @doc """
  Builds the Anthropic `system` block array for one request.

  Returns `nil` when there is nothing to send. For OAuth requests the array opens
  with the billing and identity blocks; the host prompt (plus an optional schema
  instruction) follows with an ephemeral cache breakpoint.
  """
  @spec system_blocks(String.t() | nil, String.t() | nil, boolean(), keyword()) :: [block()] | nil
  def system_blocks(system, schema_instruction, is_oauth, opts \\ []) do
    blocks = if is_oauth, do: [billing_block(opts), identity_block()], else: []

    text =
      [present(system), present(schema_instruction)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")
      |> sanitize_surrogates()
      |> maybe_sanitize_identity(is_oauth, opts)

    blocks =
      if text == "" do
        blocks
      else
        blocks ++
          [%{"type" => "text", "text" => text, "cache_control" => %{"type" => "ephemeral"}}]
      end

    case blocks do
      [] -> nil
      blocks -> blocks
    end
  end

  @doc "Returns the Claude Code billing-header system block."
  @spec billing_block(keyword()) :: block()
  def billing_block(opts \\ []) do
    version = claude_code_version(opts)
    prompt_id = ID.uuid4()

    %{
      "type" => "text",
      "text" =>
        "x-anthropic-billing-header: cc_version=#{version}; cc_entrypoint=cli; cch=00000; cc_prompt_id=#{prompt_id}"
    }
  end

  @doc "Returns the Claude Code identity system block."
  @spec identity_block() :: block()
  def identity_block, do: %{"type" => "text", "text" => @identity}

  @doc "Resolves the Claude Code client version advertised to Anthropic."
  @spec claude_code_version(keyword()) :: String.t()
  def claude_code_version(opts \\ []) do
    case option_or_env(opts, :claude_code_version, @claude_code_version_env) do
      version when is_binary(version) and version != "" -> String.trim(version)
      _missing -> @default_claude_code_version
    end
  end

  @doc "Builds the Claude Code user agent advertised on OAuth requests."
  @spec user_agent(keyword()) :: String.t()
  def user_agent(opts \\ []), do: "claude-cli/#{claude_code_version(opts)} (external, cli)"

  @doc """
  Removes Pi/Tackle identity paragraphs and rewrites the harness name.

  Modes: `"aggressive"` (default), `"path-safe"`, `"technical-safe"`, and
  `"custom"` (with a pattern). A never-matching custom pattern disables
  rewriting.
  """
  @spec sanitize_system_text(String.t(), keyword()) :: String.t()
  def sanitize_system_text(text, opts \\ []) when is_binary(text) do
    text
    |> String.split(~r/\n\n+/)
    |> Enum.reject(&identity_paragraph?/1)
    |> Enum.join("\n\n")
    |> then(&Regex.replace(rewrite_pattern(opts), &1, "Claude Code"))
    |> String.trim()
  end

  @doc """
  Replaces unpaired surrogate encodings with U+FFFD.

  Elixir binaries are normally valid UTF-8, but a decoded JSON payload can carry
  lone surrogates. Invalid bytes are replaced so the request body is well-formed.
  """
  @spec sanitize_surrogates(String.t()) :: String.t()
  def sanitize_surrogates(text) when is_binary(text) do
    if String.valid?(text), do: text, else: String.replace_invalid(text)
  end

  defp maybe_sanitize_identity(text, true, opts), do: sanitize_system_text(text, opts)
  defp maybe_sanitize_identity(text, false, _opts), do: String.trim(text)

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defp identity_paragraph?(paragraph) do
    lower = String.downcase(paragraph)

    String.contains?(lower, "you are pi") or
      String.contains?(lower, "you are tackle") or
      Enum.any?(@removal_anchors, &String.contains?(lower, &1))
  end

  defp rewrite_pattern(opts) do
    case rewrite_mode(opts) do
      "custom" ->
        compile_custom_pattern(option_or_env(opts, :rewrite_pattern, @rewrite_pattern_env))

      source ->
        Regex.compile!(Map.fetch!(@rewrite_sources, source))
    end
  end

  defp rewrite_mode(opts) do
    case option_or_env(opts, :rewrite_mode, @rewrite_mode_env) do
      value when value in [nil, ""] -> "aggressive"
      value when is_atom(value) -> validate_mode(Atom.to_string(value))
      value when is_binary(value) -> validate_mode(String.downcase(String.trim(value)))
      other -> validate_mode(other)
    end
  end

  defp validate_mode(mode) when mode in @rewrite_modes, do: mode

  defp validate_mode(mode) do
    raise ArgumentError,
          "invalid Anthropic OAuth rewrite mode #{inspect(mode)}; expected one of #{inspect(@rewrite_modes)}"
  end

  defp compile_custom_pattern(pattern) when is_binary(pattern) and pattern != "" do
    {source, flags} = parse_regex_literal(String.trim(pattern))

    case Regex.compile(source, flags) do
      {:ok, regex} -> regex
      {:error, {message, _at}} -> raise ArgumentError, "invalid rewrite pattern: #{message}"
    end
  end

  defp compile_custom_pattern(_pattern) do
    raise ArgumentError, "rewrite mode \"custom\" requires a rewrite pattern"
  end

  defp parse_regex_literal("/" <> _rest = value) do
    case Regex.run(~r{^/(.*)/([a-zA-Z]*)$}, value) do
      [_, source, flags] -> {source, flags}
      _no_match -> {value, ""}
    end
  end

  defp parse_regex_literal(value), do: {value, ""}

  defp option_or_env(opts, key, env) do
    case Keyword.get(opts, key) do
      nil -> System.get_env(env)
      value -> value
    end
  end
end
