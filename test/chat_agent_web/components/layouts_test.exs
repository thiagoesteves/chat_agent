defmodule ChatAgentWeb.LayoutsTest do
  use ChatAgentWeb.ConnCase, async: true

  # The account actions sit in the app bar next to the theme toggle, so both are
  # asserted together: the point is that they are one group, not two bars.
  describe "app bar, signed out" do
    test "offers a way in, and nothing about an account", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s(class="app-bar-actions")
      assert html =~ "Log in"
      refute html =~ "Log out"
      refute html =~ "Settings"
    end
  end

  describe "app bar, signed in" do
    setup :register_and_log_in_user

    test "names who is signed in, alongside the theme toggle", %{conn: conn, user: user} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ user.email
      assert html =~ "Settings"
      assert html =~ "Log out"

      # One group holds both, rather than a separate menu above the bar.
      assert html =~ ~s(class="app-bar-actions")
      assert [bar] = Regex.run(~r/<div class="app-bar-actions">.*?<\/header>/s, html)
      assert bar =~ "app-user"
      assert bar =~ "theme-toggle"
    end

    test "logs the user out from the bar", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s(href="#{~p"/users/log-out"}")
      assert html =~ ~s(data-method="delete")
    end
  end
end
