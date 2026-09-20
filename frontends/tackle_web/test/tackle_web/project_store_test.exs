defmodule Tackle.Web.ProjectStoreTest do
  # The store is a named process, so tests in this file are sequential. Each one
  # uses its own locator, so nothing else is disturbed either.
  use ExUnit.Case, async: false

  alias Tackle.Web.Project
  alias Tackle.Web.ProjectStore

  setup do
    slug = unique_slug()

    on_exit(fn -> ProjectStore.remove(slug) end)

    {:ok, slug: slug}
  end

  test "keeps a project and finds it by slug", %{slug: slug} do
    project = project(slug)

    assert {:ok, stored} = ProjectStore.put(project)
    assert stored.inserted_at
    assert ProjectStore.get(slug) == stored
    assert slug in Enum.map(ProjectStore.list(), & &1.slug)
  end

  test "refuses a locator that is already a project", %{slug: slug} do
    assert {:ok, _project} = ProjectStore.put(project(slug))

    assert {:error, {:duplicate, existing}} = ProjectStore.put(project(slug))
    assert existing.slug == slug
  end

  test "forgetting a project is idempotent", %{slug: slug} do
    assert {:ok, _project} = ProjectStore.put(project(slug))

    assert :ok = ProjectStore.remove(slug)
    assert ProjectStore.get(slug) == nil
    assert :ok = ProjectStore.remove(slug)
  end

  test "an unknown slug reads as nil" do
    assert ProjectStore.get("nothing-here") == nil
  end

  test "announces a change to subscribers", %{slug: slug} do
    :ok = ProjectStore.subscribe()

    assert {:ok, _project} = ProjectStore.put(project(slug))
    assert_receive {:projects_updated, _topic}

    assert :ok = ProjectStore.remove(slug)
    assert_receive {:projects_updated, _topic}
  end

  test "lists the most recently added first", %{slug: slug} do
    other = unique_slug()
    on_exit(fn -> ProjectStore.remove(other) end)

    {:ok, _first} = ProjectStore.put(project(slug))
    {:ok, _second} = ProjectStore.put(project(other))

    slugs = Enum.map(ProjectStore.list(), & &1.slug)
    assert index_of(slugs, other) < index_of(slugs, slug)
  end

  defp project(slug) do
    %Project{
      slug: slug,
      kind: :local,
      locator: "/tmp/#{slug}",
      name: Path.basename(slug),
      default_branch: "main"
    }
  end

  defp unique_slug do
    "local-test-#{System.unique_integer([:positive])}"
  end

  defp index_of(list, value), do: Enum.find_index(list, &(&1 == value))
end
