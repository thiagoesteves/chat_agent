defmodule ChatAgentWeb.PageControllerTest do
  use ChatAgentWeb.ConnCase

  describe "signed out" do
    test "describes the project without asking anyone to log in first", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "Your chats, answered by an agent you run"
      assert html =~ "WhatsApp"
      assert html =~ "Telegram"
      assert html =~ "One inbox, many channels"
    end

    test "says which endpoints are public and which need a login", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "/whatsapp/webhook"
      assert html =~ "/telegram/webhook"
      assert html =~ "/health"
      assert html =~ "Login required"
    end

    test "points at the login page, since the dashboard is not reachable yet", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~p"/users/log-in"
      refute html =~ "Open the dashboard"
    end
  end

  describe "signed in" do
    setup :register_and_log_in_user

    test "points straight at the dashboard", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "Open the dashboard"
      assert html =~ ~p"/channels"
    end
  end
end
