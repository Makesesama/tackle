defmodule Tackle.Plugins.Ollama do
  @moduledoc """
  Ollama adapter for `Tackle.Lib.LLM` and `Tackle.Lib.Decision`.

  One adapter (type id `"ollama"`) backs every Ollama server: Ollama Cloud, a
  local server, or any self-hosted one. Each is a `Tackle.Lib.LLM.Provider`
  with its own settings. Chat goes to the OpenAI-compatible
  `<base_url>/chat/completions` streaming endpoint; decisions go to Ollama's
  System One endpoint, `<base_url>/systemone`.

  ## Default providers

  A bare `Tackle.Plugins.Ollama` module stands for two providers:

    * `"ollama"`: a local server at `http://localhost:11434/v1`, no API key,
      decision models declared local. It has no chat or decision models until
      the host configures them.
    * `"ollama-cloud"`: `https://ollama.com/v1` with a required API key and a
      small curated model catalog (see `catalog_models/0`).

  ```elixir
  {:ok, cloud} = Tackle.Lib.LLM.select([Tackle.Plugins.Ollama], "ollama-cloud/gpt-oss:120b")
  {:ok, local} = Tackle.Lib.LLM.select([Tackle.Plugins.Ollama], "ollama/qwen3:8b")
  {:ok, decision} = Tackle.Lib.Decision.select([Tackle.Plugins.Ollama], "ollama/tev1:4b")
  ```

  ## Settings

  Provider settings are a JSON-compatible map with string keys:

    * `"base_url"` - OpenAI-compatible base URL. Default
      `"http://localhost:11434/v1"`.
    * `"api_key"` - `"required"` sends a bearer key; `"none"` sends no
      authorization header and never reads credentials. Default `"none"`.
    * `"api_key_env"` - environment variable consulted for the key after the
      credential store when `"api_key"` is `"required"`. Default: none, so a
      custom provider never picks up another provider's key by accident.
      `"ollama-cloud"` uses `"OLLAMA_API_KEY"`.
    * `"models"` - selectable chat model ids. Default `[]`.
    * `"decision_models"` - selectable decision model ids. Default `[]`.
    * `"model_info"` - map of model id to `Tackle.Lib.ModelInfo` fields, for
      example `%{"gpt-oss:20b" => %{"context_window" => 131_072}}`.
      Default `%{}`, so limits and prices are unknown.
    * `"local"` - whether decision models run on hardware the user controls,
      so hosts may leave their usage out of token budgets. Default `false`.

  Settings are not merged with the built-in defaults by this module: a
  provider uses exactly the settings it is given. Malformed `"models"`,
  `"decision_models"`, `"model_info"`, and `"local"` values are returned as-is
  so selection reports them.

  ## Application configuration

  Hosts can adjust the default providers, or add more, by provider id. Each
  entry is merged (one level, key by key) over the built-in settings of the
  same id:

      config :tackle_ollama, Tackle.Plugins.Ollama,
        providers: %{
          "ollama" => %{"models" => ["qwen3:8b"], "decision_models" => ["tev1:4b"]},
          "ollama-cloud" => %{"model_info" => %{"gpt-oss:120b" => %{"context_window" => 131_072}}}
        }

  A `"models"` entry replaces the built-in list, including the cloud catalog.

  ## Request options

  Selections pass `:provider_id` and `:provider_settings`. Called directly
  without `:provider_settings`, the adapter uses the default settings of
  `:provider_id` (default `"ollama"`). The base URL is `opts[:base_url]`, then
  the `"base_url"` setting, then the default. With `"api_key" => "required"`
  the key is `opts[:api_key]`, then the credential store under the provider
  id (`"api_key"` or `"key"`), then the `"api_key_env"` variable.
  `login/1` prompts for a key through a `Tackle.Lib.Interaction` handle.

  `decide/2` honours `:cancellation_signal` (an in-flight request is abandoned
  and `{:error, :cancelled}` returned) and `:receive_timeout` (default 60,000
  ms; a model may need to load on first use).
  """

  @behaviour Tackle.Lib.LLM
  @behaviour Tackle.Lib.Decision

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.CredentialStore
  alias Tackle.Lib.Decision.{Answer, Question, Request, Result}
  alias Tackle.Lib.Interaction
  alias Tackle.Lib.LLM.Error
  alias Tackle.Lib.LLM.Provider
  alias Tackle.Plugins.Ollama.HTTP
  alias Tackle.Plugins.Ollama.SSE

  @adapter_id "ollama"
  @default_base_url "http://localhost:11434/v1"
  @default_decision_timeout 60_000

  @catalog_models ["gpt-oss:120b", "gpt-oss:20b", "kimi-k3", "deepseek-v4.1-flash", "glm-5.3"]

  @builtin_providers [
    {"ollama",
     %{
       "base_url" => "http://localhost:11434/v1",
       "api_key" => "none",
       "local" => true,
       "models" => [],
       "decision_models" => []
     }},
    {"ollama-cloud",
     %{
       "base_url" => "https://ollama.com/v1",
       "api_key" => "required",
       "api_key_env" => "OLLAMA_API_KEY",
       "local" => false,
       "models" => @catalog_models,
       "decision_models" => []
     }}
  ]

  @impl Tackle.Lib.LLM
  def adapter_id, do: @adapter_id

  @doc """
  The curated Ollama Cloud model ids of the default `"ollama-cloud"` provider.

  These direct-cloud ids come from Ollama's model listing, without a local
  `:cloud` suffix. No network discovery runs.
  """
  @spec catalog_models() :: [String.t()]
  def catalog_models, do: @catalog_models

  @doc """
  The built-in `"ollama"` and `"ollama-cloud"` providers, with application
  configuration merged over them, followed by any further providers the
  application configuration declares (sorted by id).

  Raises `ArgumentError` when the application configuration is malformed.
  """
  @impl Tackle.Lib.LLM
  def default_providers do
    configured = configured_providers()
    builtin_ids = Enum.map(@builtin_providers, &elem(&1, 0))

    builtin =
      Enum.map(@builtin_providers, fn {id, settings} ->
        {id, merge_settings(settings, Map.get(configured, id))}
      end)

    extra =
      configured
      |> Map.drop(builtin_ids)
      |> Enum.sort_by(&elem(&1, 0))

    builtin ++ extra
  end

  defp merge_settings(settings, nil), do: settings
  defp merge_settings(settings, %{} = overrides), do: Map.merge(settings, overrides)
  # Kept as-is so `Tackle.Lib.LLM.Provider` reports invalid settings.
  defp merge_settings(_settings, invalid), do: invalid

  defp configured_providers do
    config = Application.get_env(:tackle_ollama, __MODULE__, [])

    unless Keyword.keyword?(config) do
      raise ArgumentError,
            "expected config :tackle_ollama, #{inspect(__MODULE__)} to be a keyword list, " <>
              "got: #{inspect(config)}"
    end

    case Keyword.get(config, :providers, %{}) do
      %{} = providers ->
        providers

      other ->
        raise ArgumentError,
              "expected config :tackle_ollama, #{inspect(__MODULE__)}, :providers to be a map " <>
                "of provider id to settings, got: #{inspect(other)}"
    end
  end

  @impl Tackle.Lib.LLM
  def models(settings) when is_map(settings), do: Map.get(settings, "models", [])

  @impl Tackle.Lib.LLM
  def model_info(model, settings) when is_map(settings) do
    case Map.get(settings, "model_info") do
      nil -> nil
      %{} = info -> Map.get(info, model)
      invalid -> invalid
    end
  end

  @impl Tackle.Lib.Decision
  def decision_models(settings) when is_map(settings),
    do: Map.get(settings, "decision_models", [])

  @impl Tackle.Lib.Decision
  def local?(settings) when is_map(settings), do: Map.get(settings, "local", false)

  @doc """
  Prompts for an API key and returns it as credentials for the host to store.

  Providers with `"api_key" => "none"` return
  `{:error, {:login_not_required, provider_id}}`.
  """
  @impl Tackle.Lib.LLM
  def login(opts) do
    with {:ok, provider} <- request_provider(opts),
         {:ok, :required} <- api_key_mode(provider),
         {:ok, interaction} <- interaction(opts),
         {:ok, api_key} <-
           Interaction.prompt(interaction, label: "Ollama API key", secret: true),
         {:ok, api_key} <- normalize_api_key(api_key) do
      {:ok, %{"api_key" => api_key}}
    else
      {:ok, :none} -> {:error, {:login_not_required, Provider.id(opts, @adapter_id)}}
      other -> other
    end
  end

  @doc """
  Reports the provider's credential state.

  `{:ok, :stored}` when a key is in the credential store or the `"api_key_env"`
  variable, `{:ok, :missing}` otherwise, and `{:ok, :not_required}` for
  providers with `"api_key" => "none"`.
  """
  @impl Tackle.Lib.LLM
  def status(opts) do
    with {:ok, provider} <- request_provider(opts),
         {:ok, mode} <- api_key_mode(provider) do
      case mode do
        :none ->
          {:ok, :not_required}

        :required ->
          case stored_or_environment_api_key(provider, opts) do
            {:ok, _api_key} -> {:ok, :stored}
            {:error, {:missing_ollama_api_key, _id}} -> {:ok, :missing}
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  defp interaction(opts) do
    case Keyword.fetch(opts, :interaction) do
      {:ok, {module, _reference} = handle} when is_atom(module) and not is_nil(module) ->
        {:ok, handle}

      _other ->
        {:error, :interaction_required}
    end
  end

  defp normalize_api_key(api_key) when is_binary(api_key) do
    if Enum.any?(:binary.bin_to_list(api_key), &(&1 < 0x20 or &1 == 0x7F)) do
      {:error, :invalid_api_key}
    else
      case String.trim(api_key) do
        "" -> {:error, :empty_api_key}
        trimmed -> if header_safe?(trimmed), do: {:ok, trimmed}, else: {:error, :invalid_api_key}
      end
    end
  end

  defp normalize_api_key(_api_key), do: {:error, :invalid_api_key}

  # A key with control characters or spaces would make the HTTP client raise
  # with the full `authorization` header in its error, so it is rejected before
  # any request is built.
  defp header_safe?(value), do: value |> :binary.bin_to_list() |> Enum.all?(&(&1 in 0x21..0x7E))

  # The provider a request runs under: its id names the credential namespace
  # and prefixes synthesized tool-call ids.
  defp request_provider(opts) do
    id = Provider.id(opts, @adapter_id)

    case Keyword.get(opts, :provider_settings) do
      %{} = settings -> {:ok, %Provider{id: id, adapter: __MODULE__, settings: settings}}
      nil -> {:ok, %Provider{id: id, adapter: __MODULE__, settings: default_settings(id)}}
      _invalid -> {:error, {:invalid_provider_settings, id, :not_a_map}}
    end
  end

  defp default_settings(id) do
    case List.keyfind(default_providers(), id, 0) do
      {^id, %{} = settings} -> settings
      _other -> %{}
    end
  end

  defp api_key_mode(%Provider{id: id, settings: settings}) do
    case Map.get(settings, "api_key", "none") do
      "none" -> {:ok, :none}
      "required" -> {:ok, :required}
      # The value may be a key pasted in by mistake, so it is not echoed.
      _invalid -> {:error, {:invalid_provider_settings, id, {"api_key", :invalid}}}
    end
  end

  defp base_url(%Provider{id: id, settings: settings}, opts) do
    case Keyword.fetch(opts, :base_url) do
      {:ok, url} when is_binary(url) and url != "" ->
        {:ok, url}

      {:ok, invalid} ->
        {:error, {:invalid_base_url, invalid}}

      :error ->
        case Map.get(settings, "base_url", @default_base_url) do
          url when is_binary(url) and url != "" -> {:ok, url}
          invalid -> {:error, {:invalid_provider_settings, id, {"base_url", invalid}}}
        end
    end
  end

  @impl Tackle.Lib.LLM
  def stream(schema, opts, event_callback) when is_function(event_callback, 1) do
    with {:ok, provider} <- request_provider(opts),
         :ok <- validate_model(models(provider.settings), opts),
         :ok <- not_cancelled(opts),
         {:ok, base_url} <- base_url(provider, opts),
         {:ok, api_key} <- api_key(provider, opts),
         {:ok, body} <- build_request_body(schema, opts),
         {:ok, response} <-
           send_request(provider.id, base_url, body, opts, api_key, event_callback),
         :ok <- not_cancelled(opts) do
      response_result(
        response,
        {provider.id, Keyword.fetch!(opts, :model)},
        schema,
        event_callback
      )
    end
  end

  defp send_request(provider_id, base_url, body, opts, api_key, event_callback) do
    signal = Keyword.get(opts, :cancellation_signal)
    initial_parser = SSE.new(provider_id)

    # Req streams body chunks of error responses too; those are collected as a
    # bounded raw body instead of being fed to the SSE parser.
    stream = fn chunk, response, acc ->
      cond do
        error_status?(response) ->
          {:cont, append_error_body(acc, chunk)}

        Cancellation.cancelled?(signal) ->
          {:halt, SSE.cancel(parser_state(acc, initial_parser))}

        true ->
          {:cont, SSE.push(parser_state(acc, initial_parser), chunk, event_callback)}
      end
    end

    with {:ok, encoded} <- encode_body(body) do
      request_options = [
        method: :post,
        url: endpoint_url(base_url, "/chat/completions"),
        headers: headers(api_key, "text/event-stream"),
        body: encoded,
        raw: true,
        retry: false,
        receive_timeout: Keyword.get(opts, :receive_timeout, 120_000)
      ]

      HTTP.stream(request_options, initial_parser, stream, opts)
    end
  end

  defp encode_body(body) do
    {:ok, JSON.encode!(body)}
  rescue
    exception -> {:error, {:invalid_request_body, Exception.message(exception)}}
  end

  @max_error_body_bytes 16_384

  defp error_status?(%{status: status}) when is_integer(status), do: status not in 200..299
  defp error_status?(_response), do: false

  defp append_error_body({:error_body, body}, chunk),
    do: {:error_body, bounded(body <> chunk)}

  defp append_error_body(_acc, chunk), do: {:error_body, bounded(chunk)}

  defp bounded(body) when byte_size(body) <= @max_error_body_bytes, do: body
  defp bounded(body), do: binary_part(body, 0, @max_error_body_bytes)

  # `identity` is the `{provider_id, requested_model}` of the request.
  defp response_result(
         %{status: status, body: body},
         {provider_id, model},
         schema,
         event_callback
       )
       when status in 200..299 do
    parser =
      case body do
        %SSE{} = parser -> parser
        body when is_binary(body) -> SSE.push(SSE.new(provider_id), body, event_callback)
        _body -> SSE.new(provider_id)
      end
      |> SSE.finish(event_callback)

    case SSE.result(parser, model, schema) do
      {:error, %Error{kind: :context_window_exceeded} = error} ->
        # Ollama may commit a 200 before the upstream rejects the prompt;
        # an overflow reported before any output is still an overflow, but
        # compacting after streamed output would repeat that output.
        if SSE.output?(parser),
          do: {:error, %{error | kind: :invalid_response}},
          else: {:error, error}

      result ->
        result
    end
  end

  defp response_result(%{status: status, body: body} = response, _identity, _schema, _callback) do
    {:error, Error.from_response(status, raw_error_body(body), Map.get(response, :headers))}
  end

  defp raw_error_body({:error_body, body}), do: body
  defp raw_error_body(%SSE{}), do: ""
  defp raw_error_body(body), do: body

  defp build_request_body(schema, opts) do
    model = Keyword.fetch!(opts, :model)

    with {:ok, tools} <- convert_tools(Keyword.get(opts, :tools, [])),
         {:ok, messages} <- convert_messages(Keyword.get(opts, :messages, [])),
         {:ok, response_format, schema_instruction} <- response_options(schema),
         {:ok, reasoning} <- reasoning_options(opts) do
      messages =
        prepend_system_and_schema(messages, Keyword.get(opts, :system), schema_instruction)

      body =
        %{
          "model" => model,
          "messages" => messages,
          "stream" => true,
          "stream_options" => %{"include_usage" => true}
        }
        |> maybe_put("tools", non_empty(tools))
        |> maybe_put("tool_choice", tool_choice(opts, tools))
        |> maybe_put("response_format", response_format)
        |> maybe_put("reasoning_effort", reasoning)
        |> maybe_put("temperature", Keyword.get(opts, :temperature))
        |> maybe_put("top_p", Keyword.get(opts, :top_p))
        |> maybe_put("max_tokens", Keyword.get(opts, :max_tokens))
        |> maybe_put("stop", Keyword.get(opts, :stop))
        |> maybe_put("user", Keyword.get(opts, :user_id))

      {:ok, body}
    end
  rescue
    KeyError -> {:error, :model_required}
  end

  defp convert_messages(messages) when is_list(messages) do
    messages
    |> Enum.reduce_while({:ok, []}, fn message, {:ok, converted} ->
      case convert_message(message) do
        {:ok, nil} -> {:cont, {:ok, converted}}
        {:ok, item} -> {:cont, {:ok, [item | converted]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, converted} ->
        converted = Enum.reverse(converted)

        case validate_tool_history(converted) do
          :ok -> {:ok, converted}
          {:error, reason} -> {:error, {:invalid_tool_history, reason}}
        end

      error ->
        error
    end
  end

  defp convert_messages(_messages), do: {:error, :invalid_messages}

  defp convert_message(message) when not is_map(message),
    do: {:error, :invalid_message}

  defp convert_message(message) do
    case normalize_role(field(message, :role)) do
      :user -> text_message("user", field(message, :content))
      :assistant -> assistant_message(message)
      :tool -> tool_message(message)
      role -> {:error, {:unsupported_message_role, role}}
    end
  end

  defp text_message(role, content) when is_binary(content),
    do: {:ok, %{"role" => role, "content" => content}}

  defp text_message(_role, _content), do: {:error, :invalid_message_content}

  # Tool-call-only assistant turns have no text content.
  defp assistant_message(message) do
    content = field(message, :content)
    tool_calls = field(message, :tool_calls) |> List.wrap()

    with :ok <- valid_optional_content(content),
         {:ok, tool_calls} <- convert_tool_calls(tool_calls) do
      if empty_content?(content) and tool_calls == [] do
        {:ok, nil}
      else
        assistant =
          %{
            "role" => "assistant",
            "content" => if(empty_content?(content), do: nil, else: content)
          }
          |> maybe_put("tool_calls", non_empty(tool_calls))
          |> put_replayed_reasoning(field(message, :provider_state))

        {:ok, assistant}
      end
    end
  end

  # `Tackle.Lib.LLM` passes only provider state this provider and model
  # produced, so its reasoning is replayed as it is.
  defp put_replayed_reasoning(assistant, provider_state) when is_map(provider_state) do
    case field(provider_state, :reasoning) do
      reasoning when is_binary(reasoning) -> Map.put(assistant, "reasoning", reasoning)
      _none -> assistant
    end
  end

  defp put_replayed_reasoning(assistant, _provider_state), do: assistant

  defp tool_message(message) do
    call_id = field(message, :tool_call_id)
    content = field(message, :content)

    if is_binary(call_id) and call_id != "" do
      case tool_text_content(content) do
        {:ok, text} -> {:ok, %{"role" => "tool", "tool_call_id" => call_id, "content" => text}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_tool_message}
    end
  end

  defp tool_text_content(content) when is_binary(content), do: {:ok, content}

  # Chat Completions tool results are text-only across Ollama's upstreams,
  # so structured parts (currently images) are replaced by an explicit note
  # instead of being dropped silently or failing the whole request.
  defp tool_text_content(content) when is_list(content) do
    content
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, texts} ->
      case tool_text_part(part) do
        {:ok, text} -> {:cont, {:ok, [text | texts]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, texts} -> {:ok, texts |> Enum.reverse() |> Enum.join("\n")}
      error -> error
    end
  end

  defp tool_text_content(_content), do: {:error, :invalid_tool_message}

  defp tool_text_part(part) when is_map(part) do
    case field(part, :type) do
      "text" ->
        case field(part, :text) do
          text when is_binary(text) -> {:ok, text}
          _text -> {:error, :invalid_message_content}
        end

      "image" ->
        {:ok, "[image content omitted: this adapter sends text-only tool results]"}

      type ->
        {:error, {:unsupported_tool_content, type}}
    end
  end

  defp tool_text_part(_part), do: {:error, :invalid_tool_message}

  defp convert_tool_calls(tool_calls) when is_list(tool_calls) do
    tool_calls
    |> Enum.reduce_while({:ok, []}, fn call, {:ok, converted} ->
      case convert_tool_call(call) do
        {:ok, item} -> {:cont, {:ok, [item | converted]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, converted} -> {:ok, Enum.reverse(converted)}
      error -> error
    end
  end

  defp convert_tool_call(call) when is_map(call) do
    function = field(call, :function) || %{}
    id = field(call, :id)
    name = field(call, :name) || field(function, :name)
    arguments = field(call, :arguments) || field(function, :arguments) || %{}

    with true <- is_binary(id) and id != "",
         true <- is_binary(name) and name != "",
         {:ok, arguments} <- encode_arguments(arguments) do
      {:ok,
       %{
         "id" => id,
         "type" => "function",
         "function" => %{"name" => name, "arguments" => arguments}
       }}
    else
      _invalid -> {:error, :invalid_tool_call}
    end
  end

  defp convert_tool_call(_call), do: {:error, :invalid_tool_call}

  defp validate_tool_history(messages) do
    messages
    |> Enum.reduce_while({:ok, MapSet.new()}, &validate_tool_message/2)
    |> case do
      {:ok, pending} ->
        if MapSet.size(pending) == 0, do: :ok, else: {:error, :missing_tool_results}

      error ->
        error
    end
  end

  defp validate_tool_message(
         %{"role" => "assistant", "tool_calls" => [_ | _]} = message,
         {:ok, pending}
       ) do
    if MapSet.size(pending) == 0 do
      start_tool_calls(message["tool_calls"])
    else
      {:halt, {:error, :missing_tool_results}}
    end
  end

  defp validate_tool_message(%{"role" => "tool"} = message, {:ok, pending}) do
    tool_call_id = message["tool_call_id"]

    if MapSet.member?(pending, tool_call_id) do
      {:cont, {:ok, MapSet.delete(pending, tool_call_id)}}
    else
      {:halt, {:error, {:unexpected_tool_result, tool_call_id}}}
    end
  end

  defp validate_tool_message(_message, {:ok, pending}) do
    if MapSet.size(pending) > 0 do
      {:halt, {:error, :missing_tool_results}}
    else
      {:cont, {:ok, pending}}
    end
  end

  defp start_tool_calls(tool_calls) do
    ids = Enum.map(tool_calls, & &1["id"])
    next_pending = MapSet.new(ids)

    if length(ids) == MapSet.size(next_pending),
      do: {:cont, {:ok, next_pending}},
      else: {:halt, {:error, :duplicate_tool_call_id}}
  end

  defp convert_tools(tools) when is_list(tools) do
    tools
    |> Enum.reduce_while({:ok, []}, fn tool, {:ok, converted} ->
      case convert_tool(tool) do
        {:ok, item} -> {:cont, {:ok, [item | converted]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, converted} -> {:ok, Enum.reverse(converted)}
      error -> error
    end
  end

  defp convert_tools(_tools), do: {:error, :invalid_tools}

  defp convert_tool(tool) when is_map(tool) do
    name = field(tool, :name)
    description = field(tool, :description)
    input_schema = field(tool, :input_schema)

    if is_binary(name) and name != "" and is_binary(description) and is_map(input_schema) do
      {:ok,
       %{
         "type" => "function",
         "function" => %{
           "name" => name,
           "description" => description,
           "parameters" => input_schema
         }
       }}
    else
      {:error, {:invalid_tool, name}}
    end
  end

  defp convert_tool(_tool), do: {:error, :invalid_tool}

  # Structured responses request JSON-schema output, which Ollama forwards
  # to upstreams that support it. The schema is also stated in the system
  # instruction because upstreams without schema support drop the parameter.
  defp response_options(nil), do: {:ok, nil, nil}

  defp response_options(%{} = schema), do: json_schema_response(schema)
  defp response_options(_schema), do: {:error, :invalid_response_schema}

  defp json_schema_response(json_schema) do
    response_format = %{
      "type" => "json_schema",
      "json_schema" => %{"name" => "response", "strict" => false, "schema" => json_schema}
    }

    instruction =
      "Return only a JSON object matching this JSON Schema: #{JSON.encode!(json_schema)}"

    {:ok, response_format, instruction}
  end

  defp prepend_system_and_schema(messages, system, schema_instruction) do
    content =
      [system, schema_instruction]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.join("\n\n")

    if content == "", do: messages, else: [%{"role" => "system", "content" => content} | messages]
  end

  defp tool_choice(opts, tools) do
    case Keyword.fetch(opts, :tool_choice) do
      {:ok, choice} -> choice
      :error when tools != [] -> "auto"
      :error -> nil
    end
  end

  # Named levels are model-defined; let Ollama interpret them.
  defp reasoning_options(opts) do
    case Keyword.get(opts, :reasoning_effort) do
      nil ->
        {:ok, nil}

      effort when effort in [:off, :none, "off", "none"] ->
        {:ok, "none"}

      effort when is_atom(effort) or is_binary(effort) ->
        value = to_string(effort)

        if value == "",
          do: {:error, {:invalid_reasoning_effort, effort}},
          else: {:ok, value}

      effort ->
        {:error, {:invalid_reasoning_effort, effort}}
    end
  end

  defp api_key(provider, opts) do
    with {:ok, mode} <- api_key_mode(provider) do
      case mode do
        :none -> {:ok, nil}
        :required -> required_api_key(provider, opts)
      end
    end
  end

  defp required_api_key(provider, opts) do
    case Keyword.get(opts, :api_key) do
      api_key when is_binary(api_key) ->
        if String.trim(api_key) == "",
          do: stored_or_environment_api_key(provider, opts),
          else: normalize_api_key(api_key)

      _missing ->
        stored_or_environment_api_key(provider, opts)
    end
  end

  defp stored_or_environment_api_key(provider, opts) do
    case Keyword.fetch(opts, :credential_store) do
      {:ok, {module, _reference} = handle} when is_atom(module) ->
        case CredentialStore.fetch(handle, provider.id) do
          {:ok, credentials} when is_map(credentials) ->
            credential_api_key(credentials) || environment_api_key(provider)

          :error ->
            environment_api_key(provider)

          {:error, reason} ->
            {:error, {:credential_store_failed, reason}}

          _other ->
            {:error, :invalid_ollama_credentials}
        end

      {:ok, _invalid} ->
        {:error, :invalid_credential_store}

      :error ->
        environment_api_key(provider)
    end
  end

  defp credential_api_key(credentials) do
    case field(credentials, :api_key) || field(credentials, :key) do
      api_key when is_binary(api_key) ->
        if String.trim(api_key) == "", do: nil, else: normalize_api_key(api_key)

      _missing ->
        nil
    end
  end

  defp environment_api_key(%Provider{id: id, settings: settings}) do
    case Map.get(settings, "api_key_env") do
      nil ->
        {:error, {:missing_ollama_api_key, id}}

      name when is_binary(name) and name != "" ->
        case System.get_env(name) do
          api_key when is_binary(api_key) ->
            if String.trim(api_key) == "",
              do: {:error, {:missing_ollama_api_key, id}},
              else: normalize_api_key(api_key)

          nil ->
            {:error, {:missing_ollama_api_key, id}}
        end

      invalid ->
        {:error, {:invalid_provider_settings, id, {"api_key_env", invalid}}}
    end
  end

  defp headers(api_key, accept) do
    authorization = if api_key, do: [{"authorization", "Bearer #{api_key}"}], else: []

    authorization ++
      [
        {"content-type", "application/json"},
        {"accept", accept},
        {"user-agent", user_agent()}
      ]
  end

  # Joins an OpenAI-compatible base URL and an endpoint path, accepting a base
  # URL that already ends with the path.
  defp endpoint_url(base_url, path) do
    base_url = String.trim_trailing(base_url, "/")

    if String.ends_with?(base_url, path), do: base_url, else: base_url <> path
  end

  defp validate_model(models, opts) do
    case Keyword.fetch(opts, :model) do
      {:ok, model} when is_binary(model) ->
        if is_list(models) and model in models,
          do: :ok,
          else: {:error, {:unsupported_model, model}}

      {:ok, model} ->
        {:error, {:unsupported_model, model}}

      :error ->
        {:error, :model_required}
    end
  end

  @impl Tackle.Lib.Decision
  def decide(%Request{} = request, opts) when is_list(opts) do
    with :ok <- Request.validate(request),
         {:ok, provider} <- request_provider(opts),
         :ok <- validate_decision_model(provider, request.model),
         :ok <- not_cancelled(opts),
         {:ok, base_url} <- base_url(provider, opts),
         {:ok, api_key} <- api_key(provider, opts),
         {:ok, body} <- encode_decision_request(request),
         {:ok, response} <- send_decision(base_url, api_key, body, opts),
         :ok <- not_cancelled(opts) do
      decision_result(response, request)
    end
  end

  defp validate_decision_model(provider, model) do
    models = decision_models(provider.settings)

    if is_list(models) and model in models,
      do: :ok,
      else: {:error, {:unsupported_model, model}}
  end

  defp encode_decision_request(request) do
    {:ok, request |> Request.to_json_map() |> JSON.encode!()}
  rescue
    exception -> {:error, {:invalid_request_body, Exception.message(exception)}}
  end

  defp send_decision(base_url, api_key, body, opts) do
    [
      method: :post,
      url: endpoint_url(base_url, "/systemone"),
      headers: headers(api_key, "application/json"),
      body: body,
      decode_body: false,
      retry: false,
      receive_timeout: Keyword.get(opts, :receive_timeout, @default_decision_timeout)
    ]
    |> HTTP.request(opts)
  end

  defp decision_result(%{status: status, body: body}, request) when status in 200..299 do
    with {:ok, decoded} <- decode_success_body(body),
         {:ok, answers} <- parse_answers(decoded["answers"], request.questions) do
      model = if is_binary(decoded["model"]), do: decoded["model"], else: request.model
      usage = if is_map(decoded["usage"]), do: decoded["usage"], else: nil
      {:ok, %Result{model: model, answers: answers, usage: usage}}
    end
  end

  defp decision_result(%{status: status, body: body} = response, _request),
    do: {:error, Error.from_response(status, body, Map.get(response, :headers))}

  defp decode_success_body(%{} = body), do: {:ok, body}

  defp decode_success_body(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _invalid -> {:error, {:invalid_decision_response, :invalid_json}}
    end
  end

  defp decode_success_body(_body), do: {:error, {:invalid_decision_response, :invalid_json}}

  # Every requested question must be answered with its own type; answers to
  # questions that were not asked are ignored.
  defp parse_answers(%{} = answers, questions) do
    Enum.reduce_while(questions, {:ok, %{}}, fn question, {:ok, parsed} ->
      case parse_answer(Map.get(answers, question.name), question) do
        {:ok, answer} -> {:cont, {:ok, Map.put(parsed, question.name, answer)}}
        {:error, detail} -> {:halt, {:error, {:invalid_decision_response, detail}}}
      end
    end)
  end

  defp parse_answers(_answers, _questions),
    do: {:error, {:invalid_decision_response, :missing_answers}}

  defp parse_answer(nil, %Question{name: name}), do: {:error, {:missing_answer, name}}

  defp parse_answer(
         %{"type" => "choice", "choice" => choice} = answer,
         %Question{type: :choice} = q
       )
       when is_binary(choice) do
    if Map.has_key?(q.criteria, choice) do
      {:ok,
       %Answer{
         type: :choice,
         choice: choice,
         probabilities: probabilities(answer["probabilities"], & &1),
         confidence: number_or_nil(answer["confidence"])
       }}
    else
      {:error, {:unknown_choice, q.name, choice}}
    end
  end

  defp parse_answer(%{"type" => "noul", "noul" => noul} = answer, %Question{type: :noul})
       when is_number(noul) and noul >= 0 and noul <= 1 do
    {:ok, %Answer{type: :noul, noul: noul / 1, confidence: number_or_nil(answer["confidence"])}}
  end

  defp parse_answer(%{"type" => "score"} = answer, %Question{type: :score} = q) do
    probabilities = probabilities(answer["probabilities"], &level_key/1)

    case answer["score"] || expected_level(probabilities) do
      score when is_number(score) ->
        {:ok,
         %Answer{
           type: :score,
           score: score,
           probabilities: probabilities,
           confidence: number_or_nil(answer["confidence"])
         }}

      _missing ->
        {:error, {:invalid_answer, q.name}}
    end
  end

  defp parse_answer(_answer, %Question{name: name}), do: {:error, {:invalid_answer, name}}

  defp probabilities(%{} = probabilities, key_fun) do
    for {key, value} <- probabilities, is_number(value), into: %{}, do: {key_fun.(key), value}
  end

  defp probabilities(_probabilities, _key_fun), do: %{}

  # Score levels are zero-based; level keys sent as "0", "1", ... become integers.
  defp level_key(key) when is_binary(key) do
    case Integer.parse(key) do
      {level, ""} when level >= 0 -> level
      _other -> key
    end
  end

  defp level_key(key), do: key

  # Ollama defines a score as the probability-weighted average of the levels.
  defp expected_level(probabilities) do
    levels = Enum.filter(probabilities, fn {level, _p} -> is_integer(level) end)

    if levels == [],
      do: nil,
      else: Enum.reduce(levels, 0.0, fn {level, p}, sum -> sum + level * p end)
  end

  defp number_or_nil(value) when is_number(value), do: value
  defp number_or_nil(_value), do: nil

  defp not_cancelled(opts) do
    if Cancellation.cancelled?(Keyword.get(opts, :cancellation_signal)),
      do: {:error, :cancelled},
      else: :ok
  end

  defp parser_state(%SSE{} = parser, _initial), do: parser
  defp parser_state(_acc, initial), do: initial
  defp normalize_role(role) when role in [:user, "user"], do: :user
  defp normalize_role(role) when role in [:assistant, "assistant"], do: :assistant
  defp normalize_role(role) when role in [:tool, "tool"], do: :tool
  defp normalize_role(role), do: role
  defp valid_optional_content(nil), do: :ok
  defp valid_optional_content(content) when is_binary(content), do: :ok
  defp valid_optional_content(_content), do: {:error, :invalid_message_content}
  defp empty_content?(content), do: content in [nil, ""]

  defp encode_arguments(arguments) when is_binary(arguments) do
    case JSON.decode(arguments) do
      {:ok, %{} = _arguments} -> {:ok, arguments}
      _invalid -> {:error, :invalid_tool_call_arguments}
    end
  end

  defp encode_arguments(%{} = arguments), do: {:ok, JSON.encode!(arguments)}
  defp encode_arguments(_arguments), do: {:error, :invalid_tool_call_arguments}

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field(_value, _key), do: nil

  # `tackle-ollama/<version>` user agent for requests from this package.
  defp user_agent do
    version = Application.spec(:tackle_ollama, :vsn) || ~c"0.1.0"
    "tackle-ollama/#{List.to_string(version)}"
  end

  defp non_empty([]), do: nil
  defp non_empty(value), do: value
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
