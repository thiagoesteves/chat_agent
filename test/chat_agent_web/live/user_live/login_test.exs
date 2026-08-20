defmodule ChatAgentWeb.UserLive.LoginTest do
  use ChatAgentWeb.ConnCase

  import Phoenix.LiveViewTest
  import ChatAgent.AccountsFixtures

  describe "login page" do
    test "renders login page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "Log in"
      assert html =~ "Log in and stay logged in"
      # There is nowhere to sign up: an account is a grant, made by whoever
      # runs this, not something a visitor gives themselves.
      refute html =~ "Sign up"
      assert html =~ "Accounts are created by whoever runs this"
    end

    # Login is by password only for now, so there is no email form to submit
    # and nothing on the page offers to send a link.
    test "offers no link login", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/users/log-in")

      refute html =~ "Log in with email"
      refute has_element?(lv, "#login_form_magic")
    end
  end

  describe "user login - password" do
    test "redirects if user logs in with valid credentials", %{conn: conn} do
      user = user_fixture() |> set_password()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form_password",
          user: %{email: user.email, password: valid_user_password(), remember_me: true}
        )

      conn = submit_form(form, conn)

      assert redirected_to(conn) == ~p"/"
    end

    test "redirects to login page with a flash error if credentials are invalid", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form_password", user: %{email: "test@email.com", password: "123456"})

      render_submit(form, %{user: %{remember_me: true}})

      conn = follow_trigger_action(form, conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "login navigation" do
    test "offers nowhere to register, and answers nothing there" do
      # The route is gone rather than hidden, so a link kept in a bookmark
      # finds nothing.
      assert get(build_conn(), "/users/register").status == 404
    end
  end

  describe "re-authentication (sudo mode)" do
    setup %{conn: conn} do
      user = user_fixture()
      %{user: user, conn: log_in_user(conn, user)}
    end

    test "shows login page with email filled in", %{conn: conn, user: user} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "You need to reauthenticate"
      refute html =~ "Sign up"

      assert html =~
               ~s(<input type="text" name="user[email]" id="login_form_password_email" value="#{user.email}")
    end
  end
end
