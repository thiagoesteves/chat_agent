defmodule ChatAgentWeb.ChannelLiveSessionTest do
  use ChatAgentWeb.ConnCase, async: false

  alias ChatAgent.Assistant
  alias ChatAgent.Channel

  setup :register_and_log_in_user

  describe "the session badge" do
    test "shows nothing while no conversation is being answered", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/channels")

      refute html =~ "session-badge"
    end

    test "names the assistant and the session once one opens", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/channels")

      Assistant.broadcast(
        {:session_opened,
         %{key: {:telegram, "123456"}, assistant: :claude, id: "a1b2c3", pid: self()}}
      )

      html = render(view)

      assert html =~ "session-badge"
      assert html =~ "claude"
      assert html =~ "a1b2c3"
    end

    test "stops showing it when the session closes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/channels")

      Assistant.broadcast(
        {:session_opened,
         %{key: {:telegram, "123456"}, assistant: :claude, id: "a1b2c3", pid: self()}}
      )

      assert render(view) =~ "a1b2c3"

      Assistant.broadcast({:session_closed, {:telegram, "123456"}})

      refute render(view) =~ "a1b2c3"
    end

    test "shows it on the channel it belongs to, and not on another", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/channels")

      Assistant.broadcast(
        {:session_opened,
         %{key: {:telegram, "123456"}, assistant: :claude, id: "a1b2c3", pid: self()}}
      )

      telegram = view |> element("section.channel-card", "telegram") |> render()
      whatsapp = view |> element("section.channel-card", "whatsapp") |> render()

      assert telegram =~ "a1b2c3"
      refute whatsapp =~ "a1b2c3"
    end

    test "follows the conversation a card would reply to", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/channels")

      # Two conversations on one channel, each with its own session.
      for {conversation, id} <- [{"111", "aaa111"}, {"222", "bbb222"}] do
        Assistant.broadcast(
          {:session_opened,
           %{key: {:telegram, conversation}, assistant: :claude, id: id, pid: self()}}
        )
      end

      :ok =
        Channel.handle_message(:telegram, %{
          "update_id" => 9,
          "message" => %{"chat" => %{"id" => 222}, "text" => "hello"}
        })

      # The badge names the session for the conversation being replied to.
      html = view |> element("section.channel-card", "telegram") |> render()

      assert html =~ "bbb222"
      refute html =~ "aaa111"
    end
  end

  describe "an assistant with no mark of its own" do
    test "still gets a badge, with a plain one", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/channels")

      Assistant.broadcast(
        {:session_opened,
         %{key: {:telegram, "123456"}, assistant: :some_other, id: "d4e5f6", pid: self()}}
      )

      html = render(view)

      assert html =~ "session-badge is-some_other"
      assert html =~ "some_other"
      assert html =~ "d4e5f6"
    end
  end

  describe "who sent a reply" do
    test "says the dashboard for one typed here", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/channels")

      Req.Test.stub(ChatAgent.Channel.Telegram, fn conn ->
        Req.Test.json(conn, %{"ok" => true, "result" => %{"message_id" => 1}})
      end)

      :ok =
        Channel.handle_message(:telegram, %{
          "update_id" => 10,
          "message" => %{"chat" => %{"id" => 123_456}, "text" => "hello"}
        })

      view
      |> form("#send-form-telegram", send: %{body: "typed by a person"})
      |> render_submit()

      assert render(view) =~ "sent from this dashboard"
    end

    test "names the assistant for one it answered", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/channels")

      Req.Test.stub(ChatAgent.Channel.Telegram, fn conn ->
        Req.Test.json(conn, %{"ok" => true, "result" => %{"message_id" => 1}})
      end)

      # What a session sends, which is not what the dashboard sends.
      :ok =
        Channel.send_message(:telegram, 123_456, "answered by an assistant",
          sender: "claude",
          identifiers: [{"session", "a1b2c3"}]
        )

      html = render(view)

      assert html =~ "sent by claude"
      refute html =~ "sent from this dashboard"
      # The session it came from is named among the message's identifiers.
      assert html =~ "a1b2c3"
    end
  end
end
