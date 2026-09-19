defmodule Tackle.Web.DiffLive do
  @moduledoc """
  Renders the diff a local repository introduces on one ref relative to another.

  The repository and the two refs live in the URL, so a review is a link that can
  be shared, bookmarked and reloaded, and the back button behaves.
  """

  use Tackle.Web, :live_view

  import Tackle.Web.Components.Diff

  alias Tackle.Web.Diff
  alias Tackle.Web.GitHub

  @default_base "HEAD~1"
  @default_head "HEAD"

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Review", pr_error: nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    repo = params |> Map.get("repo", "") |> String.trim()
    base = blank_to(params["base"], @default_base)
    head = blank_to(params["head"], @default_head)

    socket =
      socket
      |> assign(repo: repo, base: base, head: head)
      |> assign_diff(repo, base, head)

    {:noreply, socket}
  end

  @impl true
  def handle_event("open_pull_request", %{"reference" => reference}, socket) do
    case GitHub.parse(reference) do
      {:ok, {owner, name, number}} ->
        {:noreply, push_navigate(socket, to: ~p"/pulls/#{owner}/#{name}/#{number}")}

      {:error, message} ->
        {:noreply, assign(socket, :pr_error, message)}
    end
  end

  @impl true
  def handle_event("load", params, socket) do
    query = %{
      "repo" => trim(params["repo"]),
      "base" => trim(params["base"]),
      "head" => trim(params["head"])
    }

    {:noreply, push_patch(socket, to: ~p"/?#{query}")}
  end

  # Nothing to load until a repository is named; the template shows the prompt.
  defp assign_diff(socket, "", _base, _head), do: assign(socket, :diff, nil)

  defp assign_diff(socket, repo, base, head) do
    assign_async(socket, :diff, fn ->
      with {:ok, diff} <- Diff.load(repo, base, head), do: {:ok, %{diff: diff}}
    end)
  end

  defp short_sha(sha), do: String.slice(sha, 0, 8)

  # `assign_async` reports a handled failure as `{:error, reason}` and a crash in
  # the loading function as `{:exit, reason}`.
  defp failure_message({:error, reason}), do: to_string(reason)
  defp failure_message({:exit, reason}), do: "The diff could not be loaded: #{inspect(reason)}"
  defp failure_message(other), do: "The diff could not be loaded: #{inspect(other)}"

  defp blank_to(nil, default), do: default
  defp blank_to("", default), do: default
  defp blank_to(value, _default), do: String.trim(value)

  defp trim(nil), do: ""
  defp trim(value), do: String.trim(value)
end
