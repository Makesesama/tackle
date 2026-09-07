defmodule Tackle.Lib.CacheTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Cache

  describe "control/1" do
    test "returns the ephemeral marker when cache: true" do
      assert Cache.control(cache: true) == %{type: "ephemeral"}
    end

    test "returns an explicit cache_control override" do
      assert Cache.control(cache_control: %{type: "ephemeral", ttl: "1h"}) ==
               %{type: "ephemeral", ttl: "1h"}
    end

    test "returns nil when caching is not requested" do
      assert Cache.control([]) == nil
      assert Cache.control(cache: false) == nil
    end
  end

  describe "mark_system/2" do
    test "lifts string system content into a cache-marked text part" do
      messages = [
        %{role: :system, content: "you are helpful"},
        %{role: :user, content: "hi"}
      ]

      [system, user] = Cache.mark_system(messages, %{type: "ephemeral"})

      assert system.content == [
               %{type: "text", text: "you are helpful", cache_control: %{type: "ephemeral"}}
             ]

      # the user (conversation tail) is NOT marked
      assert user == %{role: :user, content: "hi"}
    end

    test "is a no-op when control is nil" do
      messages = [%{role: :system, content: "x"}]
      assert Cache.mark_system(messages, nil) == messages
    end

    test "is a no-op when there is no system message" do
      messages = [%{role: :user, content: "hi"}]
      assert Cache.mark_system(messages, %{type: "ephemeral"}) == messages
    end
  end

  describe "mark_last_tool/2" do
    test "marks only the last tool definition" do
      tools = [
        %{type: "function", function: %{name: "a"}},
        %{type: "function", function: %{name: "b"}}
      ]

      [first, last] = Cache.mark_last_tool(tools, %{type: "ephemeral"})

      refute Map.has_key?(first, :cache_control)
      assert last.cache_control == %{type: "ephemeral"}
    end

    test "is a no-op for an empty tool list or nil control" do
      assert Cache.mark_last_tool([], %{type: "ephemeral"}) == []
      assert Cache.mark_last_tool([%{a: 1}], nil) == [%{a: 1}]
    end
  end
end
