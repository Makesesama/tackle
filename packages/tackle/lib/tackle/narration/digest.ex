defmodule Tackle.Narration.Digest do
  @moduledoc """
  Bounded summary of one delegated run, and the state a narration model
  describes.

  `Tackle.Narrator` keeps one digest per running subagent or workflow child.
  It feeds the run's own (already unwrapped) child events through `observe/2`;
  the digest keeps only what a one-line status needs:

    * the run's task (its first 400 characters) and profile;
    * the last 6 tool calls as a name and a shortened argument (path,
      command, pattern, …) with their status;
    * the last 300 characters of assistant text;
    * the last 3 errors;
    * whether anything changed since the last narration, and that narration,
      so the model reports what is new instead of repeating itself.

  `state/1` renders this as a small JSON-compatible map. All text is cleaned
  of terminal control sequences and invalid UTF-8, and every cut happens on a
  character boundary.
  """

  alias Tackle.Lib.Event
  alias Tackle.PlainText

  @task_chars 400
  @text_chars 300
  @argument_chars 80
  @error_chars 160
  @max_tools 6
  @max_errors 3
  @argument_keys for key <- ~w(path file_path command pattern query url profile workflow),
                     do: {key, String.to_atom(key)}

  defstruct task: nil,
            profile: nil,
            tools: [],
            text: "",
            errors: [],
            previous: nil,
            changed?: false

  @type tool :: %{
          id: String.t() | nil,
          name: String.t(),
          argument: String.t() | nil,
          status: :running | :ok | :error
        }

  @type t :: %__MODULE__{
          task: String.t() | nil,
          profile: String.t() | nil,
          # Newest first; `state/1` lists them oldest first.
          tools: [tool()],
          text: String.t(),
          errors: [String.t()],
          previous: String.t() | nil,
          changed?: boolean()
        }

  @doc "Starts a digest for a run with an optional task and profile."
  @spec new(String.t() | nil, String.t() | nil) :: t()
  def new(task \\ nil, profile \\ nil),
    do: %__MODULE__{} |> put_task(task) |> put_profile(profile)

  @doc """
  Records the run's task when it is known and not yet recorded.

  The task may arrive after the run's first events, so a later call fills it
  in; an already recorded task is kept.
  """
  @spec put_task(t(), String.t() | nil) :: t()
  def put_task(%__MODULE__{task: nil} = digest, task) when is_binary(task) do
    case task |> PlainText.clean() |> String.trim() do
      "" -> digest
      task -> %{digest | task: PlainText.truncate(task, @task_chars)}
    end
  end

  def put_task(%__MODULE__{} = digest, _task), do: digest

  @doc "Records the run's profile when it is known and not yet recorded."
  @spec put_profile(t(), String.t() | nil) :: t()
  def put_profile(%__MODULE__{profile: nil} = digest, profile)
      when is_binary(profile) and profile != "",
      do: %{digest | profile: PlainText.clean(profile)}

  def put_profile(%__MODULE__{} = digest, _profile), do: digest

  @doc """
  Folds one of the run's own events into the digest.

  Events that say nothing about the run's work (usage, step boundaries,
  reasoning, …) leave the digest unchanged.
  """
  @spec observe(t(), Event.t()) :: t()
  def observe(%__MODULE__{} = digest, %Event{type: :tool_start, data: data}) do
    tool = %{
      id: string(Map.get(data, :tool_call_id)),
      name: PlainText.clean(string(Map.get(data, :name)) || "tool"),
      argument: argument(Map.get(data, :arguments)),
      status: :running
    }

    changed(%{digest | tools: Enum.take([tool | digest.tools], @max_tools)})
  end

  def observe(%__MODULE__{} = digest, %Event{type: :tool_execution_end, data: data}) do
    status = if Map.get(data, :status) == :failed, do: :error, else: :ok
    settle(digest, data, status)
  end

  def observe(%__MODULE__{} = digest, %Event{type: :tool_end, data: data}),
    do: settle(digest, data, :ok)

  def observe(%__MODULE__{} = digest, %Event{type: :tool_error, data: data}),
    do: settle(digest, data, :error)

  def observe(%__MODULE__{} = digest, %Event{type: :message_delta, data: data}) do
    with field when field in [nil, :content] <- Map.get(data, :field),
         delta when is_binary(delta) and delta != "" <- Map.get(data, :delta) do
      changed(%{
        digest
        | text: PlainText.last_chars(digest.text <> PlainText.clean(delta), @text_chars)
      })
    else
      _other -> digest
    end
  end

  # A new assistant message starts a new line of text, so the tail never runs
  # two messages' words together.
  def observe(%__MODULE__{text: text} = digest, %Event{type: :message_start})
      when text != "" do
    if String.ends_with?(text, "\n"), do: digest, else: %{digest | text: text <> "\n"}
  end

  def observe(%__MODULE__{} = digest, %Event{type: :error, data: data}) do
    case error_text(Map.get(data, :error)) do
      nil -> digest
      text -> digest |> put_error(text) |> changed()
    end
  end

  def observe(%__MODULE__{} = digest, %Event{}), do: digest

  @doc "Whether the digest changed since it was last taken for a narration."
  @spec changed?(t()) :: boolean()
  def changed?(%__MODULE__{changed?: changed?}), do: changed?

  @doc """
  Marks the current state as taken for a narration.

  Later events mark the digest as changed again, so a narration request that
  is in flight never hides newer work.
  """
  @spec taken(t()) :: t()
  def taken(%__MODULE__{} = digest), do: %{digest | changed?: false}

  @doc "Marks the digest as changed, for example after a failed narration."
  @spec changed(t()) :: t()
  def changed(%__MODULE__{} = digest), do: %{digest | changed?: true}

  @doc "Records the narration produced for this run."
  @spec narrated(t(), String.t()) :: t()
  def narrated(%__MODULE__{} = digest, text) when is_binary(text),
    do: %{digest | previous: text}

  @doc "Returns the narration-model state for the run."
  @spec state(t()) :: map()
  def state(%__MODULE__{} = digest) do
    %{
      "task" => digest.task,
      "profile" => digest.profile,
      "recent_tool_calls" => digest.tools |> Enum.reverse() |> Enum.map(&tool_line/1),
      "recent_assistant_text" => String.trim(digest.text),
      "errors" => Enum.reverse(digest.errors),
      "previous_status" => digest.previous
    }
  end

  # Tools ---------------------------------------------------------------------

  # A call's end is reported twice (`tool_execution_end`, then `tool_end` or
  # `tool_error`); only the first transition of a running call counts, so a
  # failed call's error is recorded once even when other calls' events come
  # in between. Calls the digest no longer lists are ignored.
  defp settle(digest, data, status) do
    id = string(Map.get(data, :tool_call_id))

    case Enum.find_index(digest.tools, &(is_binary(id) and &1.id == id and &1.status == :running)) do
      nil ->
        digest

      index ->
        tools = List.update_at(digest.tools, index, &%{&1 | status: status})
        digest = changed(%{digest | tools: tools})
        error = status == :error && error_text(Map.get(data, :error))
        if error, do: put_error(digest, Enum.at(tools, index).name <> ": " <> error), else: digest
    end
  end

  defp put_error(digest, text) do
    case digest.errors do
      [^text | _older] -> digest
      errors -> %{digest | errors: Enum.take([text | errors], @max_errors)}
    end
  end

  defp tool_line(%{name: name, argument: argument, status: status}) do
    call = if argument, do: "#{name} #{argument}", else: name
    "#{call} (#{status_text(status)})"
  end

  defp status_text(:running), do: "running"
  defp status_text(:ok), do: "ok"
  defp status_text(:error), do: "error"

  # Provider arguments are decoded JSON with string keys; accept atom keys from
  # hosts that build calls by hand.
  defp argument(arguments) when is_map(arguments) do
    Enum.find_value(@argument_keys, fn {key, atom_key} ->
      case Map.get(arguments, key, Map.get(arguments, atom_key)) do
        value when is_binary(value) -> short_line(value, @argument_chars)
        _other -> nil
      end
    end)
  end

  defp argument(_arguments), do: nil

  defp error_text(error) when is_binary(error), do: short_line(error, @error_chars)
  defp error_text(nil), do: nil
  defp error_text(error), do: error |> inspect() |> short_line(@error_chars)

  # Text ----------------------------------------------------------------------

  defp short_line(text, chars) do
    text
    |> PlainText.clean()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != ""))
    |> case do
      nil -> nil
      line -> PlainText.truncate(line, chars)
    end
  end

  defp string(value) when is_binary(value), do: value
  defp string(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp string(_value), do: nil
end
