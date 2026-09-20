defmodule Tackle.Web.Components.UITest do
  @moduledoc """
  The design system's contract: the one accent, the shapes a control can take,
  and the state a reader is told about.

  These assert the class that carries a decision (pink for interactive, an
  `aria` attribute for state) rather than the whole class list, so a screen can
  keep styling components without rewriting these tests.
  """

  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import Tackle.Web.Components.UI

  describe "button" do
    test "the asked-for action is the one filled with the accent" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.button>Send</.button>
        """)

      assert html =~ ~s(type="button")
      assert html =~ "bg-primary"
      assert html =~ "Send"
    end

    test "an alternative action is outlined rather than filled" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.button variant="ghost">Show diff</.button>
        """)

      assert html =~ "border-base-300"
      refute html =~ "bg-primary"
    end

    test "a navigation button renders a link" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.button navigate="/chat">New chat</.button>
        """)

      assert html =~ ~s(href="/chat")
      refute html =~ "<button"
    end

    test "a disabled button says so" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.button disabled={true}>Start chat</.button>
        """)

      assert html =~ "disabled"
      assert html =~ "disabled:opacity-40"
    end
  end

  describe "status" do
    test "an added thing is the only badge that takes the accent" do
      assigns = %{}

      added =
        rendered_to_string(~H"""
        <.badge tone="added">added</.badge>
        """)

      removed =
        rendered_to_string(~H"""
        <.badge tone="removed">deleted</.badge>
        """)

      assert added =~ "text-primary"
      refute removed =~ "text-primary"
    end

    test "an error is announced, a notice is not" do
      assigns = %{}

      error =
        rendered_to_string(~H"""
        <.alert tone="error">That turn failed.</.alert>
        """)

      notice =
        rendered_to_string(~H"""
        <.alert tone="brand">Read this.</.alert>
        """)

      assert error =~ ~s(role="alert")
      assert error =~ "border-error"
      assert notice =~ ~s(role="status")
      assert notice =~ "border-primary"
    end

    test "an empty state offers the actions that get out of it" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.empty_state icon="hero-check-circle" title="No changes">
          These refs point at the same tree.
          <:actions><.button variant="ghost">Show diff</.button></:actions>
        </.empty_state>
        """)

      assert html =~ "No changes"
      assert html =~ "These refs point at the same tree."
      assert html =~ "Show diff"
    end
  end

  describe "form controls" do
    test "errors are rendered under the control they belong to" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.input name="model" errors={["is not offered"]} />
        """)

      assert html =~ "text-error"
      assert html =~ "is not offered"
    end

    test "a select offers the given options and marks the current one" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.input type="select" name="model" value="b" options={[{"A", "a"}, {"B", "b"}]} />
        """)

      assert html =~ "<select"
      assert html =~ ~s(<option selected value="b">)
    end

    test "a checkbox is the accent when it is checked" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.input type="checkbox" checked={true} />
        """)

      assert html =~ "accent-primary"
      assert html =~ "checked"
    end

    test "a labelled field connects its label to the control" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.field label="Working directory" for="chat_workspace" hint="Files are read here.">
          <.input id="chat_workspace" name="chat[workspace]" />
        </.field>
        """)

      assert html =~ ~s(for="chat_workspace")
      assert html =~ ~s(id="chat_workspace")
      assert html =~ "Files are read here."
    end
  end

  describe "progress" do
    test "reports how far through the review is" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.progress value={3} max={4} />
        """)

      assert html =~ ~s(aria-valuenow="3")
      assert html =~ ~s(aria-valuemax="4")
      assert html =~ "width: 75.0%"
    end

    test "an empty review is not a division by zero" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.progress value={0} max={0} />
        """)

      assert html =~ "width: 0%"
    end
  end

  describe "navigation" do
    test "the open section is the one marked in the accent" do
      assigns = %{}

      active =
        rendered_to_string(~H"""
        <.nav_link navigate="/chat" active={true}>Chat</.nav_link>
        """)

      other =
        rendered_to_string(~H"""
        <.nav_link navigate="/chat" active={false}>Chat</.nav_link>
        """)

      assert active =~ ~s(aria-current="page")
      assert active =~ "border-primary"
      assert other =~ ~s(href="/chat")
      refute other =~ "border-primary"
    end
  end
end
