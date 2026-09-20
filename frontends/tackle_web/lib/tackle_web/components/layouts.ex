defmodule Tackle.Web.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """

  use Tackle.Web, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates("layouts/*")

  @doc """
  The app shell: the wordmark, the navigation, and the page.

  Everything happens inside a project, so there is one section to navigate to and
  it is marked in pink while a project page is open. A page fills everything
  under the navigation and scrolls its own panes, so the shell itself never
  scrolls.

  ## Examples

      <Layouts.app flash={@flash} section={:chat}>
        <h1>Content</h1>
      </Layouts.app>
  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")

  attr(:section, :atom,
    default: nil,
    doc: "which section this page belongs to, for the header navigation"
  )

  slot(:inner_block, required: true)

  def app(assigns) do
    ~H"""
    <div class="flex h-dvh flex-col overflow-hidden bg-base-100 text-base-content">
      <header class="flex flex-none items-stretch gap-1 border-b border-base-300 px-4">
        <.link
          navigate={~p"/"}
          class="mr-3 inline-flex items-center gap-2 text-sm font-semibold tracking-tight"
        >
          <span class="size-2 flex-none rounded-full bg-primary" /> Tackle
        </.link>

        <.nav_link navigate={~p"/projects"} active={@section == :projects}>Projects</.nav_link>
      </header>

      <main class="flex min-h-0 flex-1 flex-col">
        {render_slot(@inner_block)}
      </main>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")
  attr(:id, :string, default: "flash-group", doc: "the optional id of flash container")

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
    </div>
    """
  end
end
