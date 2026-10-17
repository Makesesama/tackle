defmodule Tackle.Web.UI do
  @moduledoc """
  Components of the app's own pages: the top bar with the logo, flash
  messages, page headers, status badges, times, and form inputs for
  `Phoenix.HTML.FormField`s (AshPhoenix forms). The styles are in
  `priv/static/assets/app.css`.
  """

  use Phoenix.Component

  import Phoenix.Controller, only: [get_csrf_token: 0]

  alias Phoenix.HTML.{Form, FormField}

  @doc "The logo: the pixel mark of `docs/assets/tackle-logo.svg`."
  attr :class, :string, default: "logo"

  def logo(assigns) do
    ~H"""
    <img class={@class} src="/assets/logo.svg" alt="" width="28" height="24" />
    """
  end

  @doc "The bar on top of every page: the logo, navigation, and who is signed in."
  attr :current_user, :any, default: nil

  def top_bar(assigns) do
    ~H"""
    <header class="topbar">
      <a class="brand" href="/"><.logo />tackle</a>
      <nav :if={@current_user}>
        <a href="/repos">Repositories</a>
        <a href="/settings">Models</a>
        <a :if={@current_user.admin} href="/admin">Admin</a>
      </nav>
      <div :if={@current_user} class="who">
        <span class="muted">{@current_user.login}</span>
        <form action="/sign-out" method="post">
          <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
          <button type="submit" class="link">Sign out</button>
        </form>
      </div>
    </header>
    """
  end

  @doc "The flash messages of a LiveView page."
  attr :flash, :map, required: true

  def flash(assigns) do
    ~H"""
    <div
      :for={{kind, message} <- Enum.filter(@flash, fn {kind, _} -> kind in ["info", "error"] end)}
      class={"flash flash-#{kind}"}
      role="status"
      phx-click="lv:clear-flash"
      phx-value-key={kind}
    >
      {message}
    </div>
    """
  end

  @doc "A page's title, with an optional line under it and actions to the right."
  attr :title, :string, required: true
  slot :subtitle
  slot :actions

  def page_header(assigns) do
    ~H"""
    <div class="page-header">
      <div>
        <h1>{@title}</h1>
        <p :if={@subtitle != []} class="muted">{render_slot(@subtitle)}</p>
      </div>
      <div :if={@actions != []} class="actions">{render_slot(@actions)}</div>
    </div>
    """
  end

  @doc "A review request's status, in words."
  attr :status, :atom, required: true

  def status_badge(assigns) do
    ~H"""
    <span class={"badge status-#{@status}"}>{status_label(@status)}</span>
    """
  end

  @doc "The words for a review request's status."
  @spec status_label(atom()) :: String.t()
  def status_label(:pending), do: "Queued"
  def status_label(:running), do: "Reviewing"
  def status_label(:reviewed), do: "Posting"
  def status_label(:posted), do: "Posted"
  def status_label(:failed), do: "Failed"
  def status_label(:skipped), do: "Skipped"

  @doc "A run's verdict."
  attr :verdict, :atom, default: nil

  def verdict_badge(assigns) do
    ~H"""
    <span :if={@verdict} class={"badge verdict-#{@verdict}"}>{verdict_label(@verdict)}</span>
    """
  end

  defp verdict_label(:blocking), do: "Blocking"
  defp verdict_label(:optional), do: "Suggestions"
  defp verdict_label(:clean), do: "Clean"

  @doc "When something happened: relative, with the exact time on hover."
  attr :at, :any, required: true

  def time(assigns) do
    ~H"""
    <time :if={@at} datetime={iso(@at)} title={exact(@at)}>{ago(@at)}</time>
    """
  end

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso(%NaiveDateTime{} = at), do: NaiveDateTime.to_iso8601(at) <> "Z"

  defp exact(at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  @doc "How long ago `at` was, in words."
  @spec ago(DateTime.t() | NaiveDateTime.t(), DateTime.t()) :: String.t()
  def ago(at, now \\ DateTime.utc_now())

  def ago(%NaiveDateTime{} = at, now), do: ago(DateTime.from_naive!(at, "Etc/UTC"), now)

  def ago(%DateTime{} = at, now) do
    case DateTime.diff(now, at) do
      seconds when seconds < 60 -> "just now"
      seconds when seconds < 3600 -> "#{div(seconds, 60)} min ago"
      seconds when seconds < 86_400 -> "#{div(seconds, 3600)} h ago"
      seconds when seconds < 30 * 86_400 -> "#{div(seconds, 86_400)} d ago"
      _older -> Calendar.strftime(at, "%Y-%m-%d")
    end
  end

  @doc "A commit SHA, shortened."
  attr :sha, :string, required: true

  def sha(assigns) do
    ~H"""
    <code class="sha" title={@sha}>{String.slice(@sha, 0, 7)}</code>
    """
  end

  @doc "The words for a repository's automatic review mode."
  @spec auto_review_label(atom()) :: String.t()
  def auto_review_label(:off), do: "On command"
  def auto_review_label(:on_open), do: "New pull requests"
  def auto_review_label(:on_open_and_push), do: "Every push"

  @doc "A box saying there is nothing to show yet."
  slot :inner_block, required: true

  def empty(assigns) do
    ~H"""
    <div class="empty">{render_slot(@inner_block)}</div>
    """
  end

  @doc """
  A labelled form input for a form field, with the field's errors. `type`
  is any HTML input type, or `"select"` (with `options`), `"textarea"`, or
  `"checkbox"`.
  """
  attr :field, FormField, required: true
  attr :label, :string, default: nil
  attr :type, :string, default: "text"
  attr :options, :list, default: []
  attr :help, :string, default: nil
  attr :value, :any, default: nil, doc: "shown instead of the field's value"
  attr :rest, :global, include: ~w(placeholder autocomplete required rows min max step list)

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign(
        assigns,
        :checked,
        Form.normalize_value("checkbox", assigns.field.value)
      )

    ~H"""
    <div class="field checkbox">
      <label>
        <input type="hidden" name={@field.name} value="false" />
        <input type="checkbox" id={@field.id} name={@field.name} value="true" checked={@checked} {@rest} />
        {@label}
      </label>
      <p :if={@help} class="help">{@help}</p>
      <.errors field={@field} />
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="field">
      <label for={@field.id}>{@label}</label>
      <select id={@field.id} name={@field.name} {@rest}>
        {Form.options_for_select(@options, @field.value)}
      </select>
      <p :if={@help} class="help">{@help}</p>
      <.errors field={@field} />
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="field">
      <label for={@field.id}>{@label}</label>
      <textarea id={@field.id} name={@field.name} {@rest}>{Form.normalize_value(
        "textarea",
        @value || @field.value
      )}</textarea>
      <p :if={@help} class="help">{@help}</p>
      <.errors field={@field} />
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class="field">
      <label for={@field.id}>{@label}</label>
      <input
        type={@type}
        id={@field.id}
        name={@field.name}
        value={Form.normalize_value(@type, @value || @field.value)}
        {@rest}
      />
      <p :if={@help} class="help">{@help}</p>
      <.errors field={@field} />
    </div>
    """
  end

  attr :field, FormField, required: true

  defp errors(assigns) do
    ~H"""
    <p :for={error <- @field.errors} class="error">{error_message(error)}</p>
    """
  end

  @doc "An error of a form field as text."
  @spec error_message({String.t(), keyword()} | String.t()) :: String.t()
  def error_message({message, values}) do
    Enum.reduce(values, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", text(value))
    end)
  end

  def error_message(message) when is_binary(message), do: message

  defp text(value) when is_binary(value) or is_number(value) or is_atom(value),
    do: to_string(value)

  defp text(value), do: inspect(value)
end
