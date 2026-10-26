defmodule Tackle.Session.Title do
  @moduledoc """
  LLM-generated session titles.

  Once an untitled durable session has journaled a message the user wrote,
  one tool-free generation call produces a concise task title that is
  committed through the journal's metadata path and surfaces in the catalog
  and every frontend. Only the user's own input counts: a turn's input, or a
  user message queued during a turn; agent messages, background notices, and
  hook feedback never title a session. For a new session this is its first
  prompt; a resumed session that is still untitled is titled from the next
  message the user writes. The call runs in a task under the session's work
  supervisor, concurrently with the turn, so the title is ready soon after
  the prompt instead of after the turn (`start/5`).

  A session's title goes through these states (`t:t/0`):

    * `:untitled` - no title yet; the next message the user writes starts a
      generation when titles are configured.
    * `{:pending, task}` - a generation task runs.
    * `{:titled, title}` - the journal records `title`, generated or set
      explicitly through the session spec. A titled session never
      generates another.
    * `:failed` - the generation failed, crashed, or could not start. The
      session stays untitled and this session process does not try again; a
      later resume of the still untitled session does.

  The prompt and normalization follow codex-rs thread titles
  (`codex-rs/tui/src/app/thread_title.rs`): a byte-bounded prompt over the
  user's message, and a normalized single-line title of at most
  `@max_chars` characters. The call goes through the session's adapter
  selection (or a dedicated one configured through `Tackle.Config.SessionTitles`)
  with no tools, so it cannot execute anything or read the conversation beyond
  the message it titles.
  """

  require Logger

  alias Tackle.Config
  alias Tackle.Config.SessionTitles
  alias Tackle.Lib.LLM
  alias Tackle.Lib.LLM.Response
  alias Tackle.Lib.LLM.Selection
  alias Tackle.Runtime.Task, as: TitleTask
  alias Tackle.Session.Journal

  # Codex THREAD_TITLE_MAX_CHARS: titles stay scannable in lists and tabs.
  @max_chars 36

  # Codex THREAD_TITLE_PROMPT_MAX_BYTES: bounds the title request even for
  # dense Unicode prompts.
  @prompt_max_bytes 960

  @quote_chars ["\"", "'", "`", "“", "”", "‘", "’"]
  @trailing_punctuation [".", "?", "!"]

  @typedoc "A session's title; see the module docs."
  @type t :: :untitled | {:pending, TitleTask.t()} | {:titled, String.t()} | :failed

  @doc "The title of a session whose journal records `title`, `nil` when none."
  @spec new(String.t() | nil) :: t()
  def new(nil), do: :untitled
  def new(title) when is_binary(title), do: {:titled, title}

  @doc "The title's text, or `nil` while the session is untitled."
  @spec current(t()) :: String.t() | nil
  def current({:titled, title}), do: title
  def current(_title), do: nil

  @doc """
  Starts generating a durable session's title from `content`, a message the
  user wrote, under `supervisor`; the caller owns the task and passes its
  result to `finish/1`.

  Returns `:untitled` and starts nothing for a session without a journal,
  without `Tackle.Config.SessionTitles` configured, or for blank content.
  The task waits behind the journal's outstanding commits, generates the
  title, and commits it through `Tackle.Session.Journal.metadata_changed/2`,
  returning `{:ok, title}` or `{:error, reason}`. A dedicated title model
  wins when one is configured; otherwise the call reuses the session's
  selection and LLM options, which carry its credential store.
  """
  @spec start(Config.t(), pid() | nil, Supervisor.supervisor(), String.t(), String.t() | nil) ::
          t()
  def start(%Config{} = config, journal, supervisor, session_id, content) do
    if titleable?(config, journal, content),
      do: start_task(config, journal, supervisor, session_id, content),
      else: :untitled
  end

  @doc """
  Settles a title task: its result, or `{:exit, reason}` when it crashed.
  A failure only leaves the session untitled; it is logged at debug level
  and never surfaces as a session error.
  """
  @spec finish({:ok, String.t()} | {:error, term()} | {:exit, term()}) :: t()
  def finish({:ok, title}) when is_binary(title), do: {:titled, title}

  def finish({:exit, _reason}) do
    Logger.debug("session title generation crashed")
    :failed
  end

  def finish({:error, reason}) do
    Logger.debug("session title generation failed: #{inspect(reason)}")
    :failed
  end

  @doc "Stops a pending title task."
  @spec shutdown(t(), timeout()) :: :ok
  def shutdown({:pending, task}, timeout) do
    TitleTask.shutdown(task, timeout)
    :ok
  end

  def shutdown(_title, _timeout), do: :ok

  @doc """
  Generates one session title for `user_message` through `selection`.

  `llm_opts` carries the session's LLM options and credential store, the same
  options the agent loop uses; they cannot replace the title request's own
  messages, tools, tool choice, or temperature (see
  `Tackle.Lib.LLM.request_opts/3`). The selection carries its provider's
  settings. A response that still contains tool calls is rejected; the model
  was asked for text only.
  """
  @spec generate(Selection.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def generate(%Selection{} = selection, user_message, llm_opts \\ [])
      when is_binary(user_message) do
    request = [
      messages: [%{role: :user, content: prompt(user_message)}],
      temperature: 0.2,
      tools: [],
      tool_choice: "none"
    ]

    with {:ok, response} <-
           LLM.generate_with(selection, nil, LLM.request_opts(request, [], llm_opts)) do
      title_from_response(response)
    end
  end

  @doc """
  Builds the bounded title request without truncating a Unicode character.

  Mirrors codex `thread_title_prompt`: instructions, then the trimmed user
  message, cut at `@prompt_max_bytes` on a codepoint boundary.
  """
  @spec prompt(String.t()) :: String.t()
  def prompt(user_message) when is_binary(user_message) do
    prefix = instructions() <> "\n\nUser prompt:\n"
    remaining = max(@prompt_max_bytes - byte_size(prefix), 0)

    user_message
    |> String.trim()
    |> take_bytes(remaining)
    |> then(&(prefix <> &1))
  end

  @doc """
  Normalizes a generated title the way codex `parse_thread_title` does.

  Trims, strips wrapping quotes, collapses whitespace to single spaces,
  removes trailing sentence punctuation, and truncates to `@max_chars`
  codepoints without splitting one. An empty result is invalid rather than a
  blank title.
  """
  @spec normalize(term()) :: {:ok, String.t()} | {:error, :invalid_title}
  def normalize(raw) when is_binary(raw) do
    title =
      raw
      |> String.trim()
      |> trim_wrapping_quotes()
      |> String.split()
      |> Enum.join(" ")
      |> trim_trailing_punctuation()
      |> String.trim()
      |> String.slice(0, @max_chars)

    if title == "", do: {:error, :invalid_title}, else: {:ok, title}
  end

  def normalize(_raw), do: {:error, :invalid_title}

  defp titleable?(%Config{session_titles: %SessionTitles{}}, journal, content)
       when not is_nil(journal) and is_binary(content),
       do: String.trim(content) != ""

  defp titleable?(_config, _journal, _content), do: false

  defp start_task(config, journal, supervisor, session_id, content) do
    selection = selection(config)
    llm_opts = Keyword.put(config.llm_opts, :session_id, session_id)
    generate = fn -> generate_and_commit(journal, selection, content, llm_opts) end

    case TitleTask.start(supervisor, generate) do
      {:ok, task} ->
        {:pending, task}

      {:error, reason} ->
        Logger.debug("session title task failed to start: #{inspect(reason)}")
        :failed
    end
  end

  # A title is also a model effect: wait behind outstanding commits.
  defp generate_and_commit(journal, selection, content, llm_opts) do
    with :ok <- Journal.await_idle(journal),
         {:ok, title} <- generate(selection, content, llm_opts),
         :ok <- Journal.metadata_changed(journal, %{"title" => title}) do
      {:ok, title}
    end
  end

  defp selection(%Config{session_titles: %SessionTitles{selection: %Selection{} = selection}}),
    do: selection

  defp selection(%Config{llm: %Selection{} = selection}), do: selection

  defp title_from_response(%Response{tool_calls: [_ | _]}), do: {:error, :title_tool_calls}

  defp title_from_response(%Response{content: content}) when is_binary(content),
    do: normalize(content)

  defp title_from_response(%Response{}), do: {:error, :invalid_title_response}

  defp instructions do
    "Generate a concise, single-line task title of at most #{@max_chars} characters " <>
      "and under five words where possible. Start with an imperative verb. " <>
      "Capitalize only the first word unless the user's language, proper nouns, " <>
      "acronyms, or code terms require otherwise. Preserve ticket references exactly. " <>
      "Write in the user's language. Do not use quotes, markdown, or trailing punctuation. " <>
      "Do not answer the request."
  end

  defp take_bytes(text, max_bytes) when byte_size(text) <= max_bytes, do: text

  defp take_bytes(text, max_bytes) do
    text
    |> String.codepoints()
    |> Enum.reduce_while({<<>>, 0}, fn codepoint, {acc, size} ->
      codepoint_size = byte_size(codepoint)

      if size + codepoint_size <= max_bytes do
        {:cont, {acc <> codepoint, size + codepoint_size}}
      else
        {:halt, {acc, size}}
      end
    end)
    |> elem(0)
  end

  # Codex trims any combination of these quote characters from both ends.
  defp trim_wrapping_quotes(text, chars \\ @quote_chars)

  defp trim_wrapping_quotes(text, []), do: text

  defp trim_wrapping_quotes(text, [char | rest]),
    do: text |> trim_char(char) |> trim_wrapping_quotes(rest)

  defp trim_trailing_punctuation(text, chars \\ @trailing_punctuation)

  defp trim_trailing_punctuation(text, []), do: text

  defp trim_trailing_punctuation(text, [char | rest]),
    do: text |> String.trim_trailing(char) |> trim_trailing_punctuation(rest)

  defp trim_char(text, char),
    do: text |> String.trim_leading(char) |> String.trim_trailing(char)
end
