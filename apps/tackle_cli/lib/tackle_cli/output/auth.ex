defmodule Tackle.CLI.Output.Auth do
  @moduledoc "Renders provider authentication commands for terminal and machine use."

  alias Tackle.CLI.Output

  @provider_width 24
  @status_width 10
  @flag_width 5
  @table_breakpoint 48

  @type status_result :: {:ok, term()} | {:error, term()}
  @type status_entry :: %{provider: map(), result: status_result()}
  @type usage_entry :: %{provider: String.t(), result: {:ok, map()} | {:error, term()}}

  @doc "Renders the result of login, logout, or an aborted action."
  @spec render_action(:login | :logout, String.t(), :ok | :aborted, Output.t()) :: Owl.Data.t()
  def render_action(action, provider, status, %Output{format: :json}) do
    JSON.encode!(%{
      "action" => to_string(action),
      "provider" => provider,
      "status" => to_string(status)
    })
  end

  def render_action(action, provider, status, %Output{format: :plain}) do
    ["action\tprovider\tstatus", Enum.join([action, provider, status], "\t")]
    |> Enum.join("\n")
  end

  def render_action(:login, provider, :ok, %Output{} = output) do
    [
      Output.style(output, :success, "✓"),
      " Authenticated with ",
      Output.style(output, :heading, provider),
      "."
    ]
  end

  def render_action(:logout, provider, :ok, %Output{} = output) do
    [
      Output.style(output, :success, "✓"),
      " Logged out of ",
      Output.style(output, :heading, provider),
      "."
    ]
  end

  def render_action(:logout, provider, :aborted, %Output{} = output) do
    [
      Output.style(output, :warning, "!"),
      " Logout from ",
      Output.style(output, :heading, provider),
      " cancelled."
    ]
  end

  @doc "Renders provider credential status and supported authentication flows."
  @spec render_status([status_entry()], Output.t()) :: Owl.Data.t()
  def render_status(entries, %Output{format: :json}) do
    JSON.encode!(%{"providers" => Enum.map(entries, &json_status/1)})
  end

  def render_status(entries, %Output{format: :plain}) do
    rows =
      Enum.map(entries, fn %{provider: provider, result: result} ->
        Enum.join(
          [
            provider.id,
            status_value(result),
            supported_label(provider.capabilities.login),
            supported_label(provider.capabilities.usage)
          ],
          "\t"
        )
      end)

    Enum.join(["provider\tstatus\tlogin\tusage" | rows], "\n")
  end

  def render_status([], %Output{} = output) do
    Output.style(output, :muted, "No authentication providers are configured.")
  end

  def render_status(entries, %Output{width: width} = output) when width < @table_breakpoint do
    entries
    |> Enum.map(&render_stacked_status(&1, output))
    |> Enum.intersperse("\n")
  end

  def render_status(entries, %Output{} = output) do
    provider_width =
      entries
      |> Enum.map(&Owl.Data.length(&1.provider.id))
      |> Enum.max(fn -> 0 end)
      |> max(Owl.Data.length("PROVIDER"))
      |> min(@provider_width)

    header =
      status_row(
        Output.style(output, :heading, "PROVIDER"),
        Output.style(output, :heading, "STATUS"),
        Output.style(output, :heading, "LOGIN"),
        Output.style(output, :heading, "USAGE"),
        provider_width
      )

    row_width = provider_width + @status_width + @flag_width * 2 + 6
    divider = Output.style(output, :muted, String.duplicate("─", row_width))

    rows =
      Enum.map(entries, fn %{provider: provider, result: result} ->
        status_row(
          provider.id,
          style_status(output, result),
          style_supported(output, provider.capabilities.login),
          style_supported(output, provider.capabilities.usage),
          provider_width
        )
      end)

    [header, divider | rows] |> Enum.intersperse("\n")
  end

  @doc "Renders account usage reports returned by configured providers."
  @spec render_usage([usage_entry()], Output.t()) :: Owl.Data.t()
  def render_usage(entries, %Output{format: :json}) do
    JSON.encode!(%{
      "providers" =>
        Enum.map(entries, fn %{provider: provider, result: result} ->
          case result do
            {:ok, report} -> %{"provider" => provider, "usage" => json_value(report)}
            {:error, reason} -> %{"error" => error_message(reason), "provider" => provider}
          end
        end)
    })
  end

  def render_usage(entries, %Output{format: :plain}) do
    rows =
      Enum.map(entries, fn %{provider: provider, result: result} ->
        case result do
          {:ok, report} ->
            Enum.join([provider, "ok", JSON.encode!(json_value(report))], "\t")

          {:error, reason} ->
            Enum.join([provider, "error", plain_field(error_message(reason))], "\t")
        end
      end)

    Enum.join(["provider\tstatus\tusage" | rows], "\n")
  end

  def render_usage([], %Output{} = output) do
    Output.style(output, :muted, "No configured providers report account usage.")
  end

  def render_usage(entries, %Output{} = output) do
    entries
    |> Enum.map(&render_usage_entry(&1, output))
    |> Enum.intersperse("\n\n")
  end

  @doc "Renders an authentication error without exposing an internal tuple as the headline."
  @spec render_error(term(), Output.t()) :: Owl.Data.t()
  def render_error(reason, %Output{format: :json}) do
    JSON.encode!(%{
      "error" => %{
        "code" => error_code(reason),
        "message" => error_message(reason)
      }
    })
  end

  def render_error(reason, %Output{format: :plain}) do
    Enum.join(["error", error_code(reason), plain_field(error_message(reason))], "\t")
  end

  def render_error(reason, %Output{} = output) do
    [
      Output.style(output, :danger, "Error:"),
      " ",
      error_message(reason),
      error_hint(reason, output)
    ]
  end

  @doc false
  @spec error_message(term()) :: String.t()
  def error_message({:interactive_auth_requires_human_output, flow}) do
    "Auth #{flow} is interactive and only supports human output. Remove `--format` or use `--format human`."
  end

  def error_message({:unsupported_auth_provider, provider, {:supported, supported}}) do
    suffix = supported_providers(supported)
    "Provider #{inspect(provider)} is not configured." <> suffix
  end

  def error_message({:invalid_auth_provider, _provider, {:supported, supported}}) do
    "A non-empty provider name is required." <> supported_providers(supported)
  end

  def error_message({:unsupported_provider_flow, provider, flow}) do
    "Provider #{inspect(provider)} does not support auth #{flow}."
  end

  def error_message({:http_error, status, _body}) do
    "The provider returned HTTP #{status}."
  end

  def error_message({:adapter_callback_failed, adapter, callback, detail}) do
    provider = adapter |> Module.split() |> List.last()
    "#{provider} failed while running #{callback}: #{safe_detail(detail)}"
  end

  def error_message({:credential_store_failed, _detail}),
    do: "The credential store could not be accessed."

  def error_message({:prompt_failed, _detail}), do: "The credential prompt failed."

  def error_message({:invalid_credentials, _detail}),
    do: "The provider returned invalid credentials."

  def error_message(:missing_codex_credentials),
    do: "No OpenAI Codex credentials are stored. Run `tackle auth login openai-codex`."

  def error_message(:missing_deepseek_api_key),
    do: "No DeepSeek API key is available. Run `tackle auth login deepseek`."

  def error_message(:no_credentials), do: "No credentials are stored for this provider."
  def error_message(:timeout), do: "The provider request timed out."
  def error_message(:cancelled), do: "Authentication was cancelled."
  def error_message(reason) when is_atom(reason), do: reason |> to_string() |> humanize()

  def error_message(reason) when is_binary(reason),
    do: reason |> single_line() |> String.slice(0, 512)

  def error_message(reason) do
    "Authentication failed (#{error_code(reason)})."
  end

  defp render_stacked_status(%{provider: provider, result: result}, output) do
    [
      Output.style(output, :heading, provider.id),
      "\n  ",
      style_status(output, result),
      " · login ",
      style_supported(output, provider.capabilities.login),
      " · usage ",
      style_supported(output, provider.capabilities.usage)
    ]
  end

  defp status_row(provider, status, login, usage, provider_width) do
    [
      align(provider, provider_width),
      "  ",
      align(status, @status_width),
      "  ",
      align(login, @flag_width),
      "  ",
      align(usage, @flag_width)
    ]
  end

  defp align(value, width) do
    value = Owl.Data.truncate(value, width)
    [value, String.duplicate(" ", max(width - Owl.Data.length(value), 0))]
  end

  defp style_status(output, {:ok, status}) when status in [:stored, "stored"],
    do: Output.style(output, :success, "stored")

  defp style_status(output, {:ok, status}) when status in [:missing, "missing"],
    do: Output.style(output, :warning, "missing")

  defp style_status(output, {:ok, status}),
    do: Output.style(output, :warning, scalar(status))

  defp style_status(output, {:error, reason}),
    do: Output.style(output, :danger, "error: #{error_message(reason)}")

  defp render_usage_entry(%{provider: provider, result: {:ok, report}}, output) do
    [
      Output.style(output, :heading, provider),
      "\n",
      render_fields(report, 1, output)
    ]
  end

  defp render_usage_entry(%{provider: provider, result: {:error, reason}}, output) do
    [
      Output.style(output, :heading, provider),
      "\n  ",
      Output.style(output, :danger, "Error:"),
      " ",
      error_message(reason)
    ]
  end

  defp render_fields(map, depth, output) when is_map(map) and map_size(map) == 0 do
    [indent(depth), Output.style(output, :muted, "(empty)")]
  end

  defp render_fields(map, depth, output) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, value} -> render_field(key, value, depth, output) end)
    |> Enum.intersperse("\n")
  end

  defp render_field(key, value, depth, output) when is_map(value) or is_list(value) do
    [
      indent(depth),
      Output.style(output, :accent, humanize(key)),
      ":",
      render_collection(value, depth + 1, output)
    ]
  end

  defp render_field(key, value, depth, output) do
    [
      indent(depth),
      Output.style(output, :accent, humanize(key)),
      ": ",
      scalar(value)
    ]
  end

  defp render_collection(value, _depth, output) when value in [%{}, []] do
    [" ", Output.style(output, :muted, "(empty)")]
  end

  defp render_collection(map, depth, output) when is_map(map) do
    ["\n", render_fields(map, depth, output)]
  end

  defp render_collection(list, depth, output) when is_list(list) do
    [
      "\n",
      list
      |> Enum.map(&render_list_item(&1, depth, output))
      |> Enum.intersperse("\n")
    ]
  end

  defp render_list_item(value, depth, output) when is_map(value) do
    [indent(depth), "-\n", render_fields(value, depth + 1, output)]
  end

  defp render_list_item(value, depth, _output), do: [indent(depth), "- ", scalar(value)]

  defp json_status(%{provider: provider, result: result}) do
    base = %{
      "capabilities" => json_value(provider.capabilities),
      "models" => provider.models,
      "provider" => provider.id
    }

    case result do
      {:ok, status} ->
        Map.put(base, "status", json_value(status))

      {:error, reason} ->
        Map.merge(base, %{"error" => error_message(reason), "status" => "error"})
    end
  end

  defp status_value({:ok, status}), do: scalar(status)
  defp status_value({:error, reason}), do: "error: " <> plain_field(error_message(reason))

  defp style_supported(output, true), do: Output.style(output, :success, "yes")
  defp style_supported(output, false), do: Output.style(output, :muted, "no")

  defp supported_label(true), do: "yes"
  defp supported_label(false), do: "no"

  defp error_hint({:unsupported_provider_flow, _provider, _flow}, output) do
    ["\n", Output.style(output, :muted, "Run `tackle auth status` to see supported flows.")]
  end

  defp error_hint(_reason, _output), do: []

  defp supported_providers([]), do: " No providers are currently available."

  defp supported_providers(providers) do
    " Available providers: " <> Enum.join(providers, ", ") <> "."
  end

  defp error_code({code, _rest}) when is_atom(code), do: to_string(code)
  defp error_code({code, _one, _two}) when is_atom(code), do: to_string(code)
  defp error_code(code) when is_atom(code), do: to_string(code)
  defp error_code(_reason), do: "auth_error"

  defp json_value(value) when is_map(value) do
    Map.new(value, fn {key, child} -> {to_string(key), json_value(child)} end)
  end

  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)
  defp json_value(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp json_value(nil), do: nil
  defp json_value(value) when is_atom(value), do: to_string(value)
  defp json_value(value), do: inspect(value, printable_limit: 512)

  defp scalar(nil), do: "null"
  defp scalar(value) when is_binary(value), do: value
  defp scalar(value) when is_atom(value) or is_number(value), do: to_string(value)
  defp scalar(value), do: value |> json_value() |> JSON.encode!()

  defp safe_detail(detail) when is_binary(detail), do: single_line(detail)

  defp safe_detail({kind, reason}) when kind in [:exit, :throw],
    do: "#{kind}: #{safe_detail(reason)}"

  defp safe_detail(reason) when is_atom(reason), do: humanize(reason)
  defp safe_detail(_detail), do: "provider callback failed"

  defp plain_field(value) do
    value
    |> to_string()
    |> String.replace(["\t", "\n", "\r"], " ")
  end

  defp single_line(value), do: String.replace(value, ~r/\s+/u, " ") |> String.trim()

  defp humanize(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
  end

  defp indent(depth), do: String.duplicate("  ", depth)
end
