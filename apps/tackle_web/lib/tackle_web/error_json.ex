defmodule Tackle.Web.ErrorJSON do
  @moduledoc false

  # Renders errors as `{"errors": {"detail": "Not Found"}}`, without details.
  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
