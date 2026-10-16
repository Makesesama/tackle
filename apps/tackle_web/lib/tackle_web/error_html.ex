defmodule Tackle.Web.ErrorHTML do
  @moduledoc false

  # Renders errors of browser routes as their status message, without details.
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end
