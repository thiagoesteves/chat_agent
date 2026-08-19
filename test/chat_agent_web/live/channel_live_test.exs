defmodule ChatAgentWeb.ChannelLiveTest do
  use ChatAgentWeb.ConnCase, async: true

  setup :register_and_log_in_user

  alias ChatAgent.Channel

  test "lists every configured channel", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/channels")

    assert html =~ "whatsapp"
    assert html =~ "ChatAgent.Channel.Whatsapp"
    assert html =~ "telegram"
    assert html =~ "ChatAgent.Channel.Telegram"
  end

  test "only subscribes once connected", %{conn: conn} do
    # The static render has no socket, so it reports that it is still connecting.
    html = conn |> get(~p"/channels") |> html_response(200)
    assert html =~ "Connecting"
    refute html =~ "Subscribed"

    {:ok, _view, html} = live(conn, ~p"/channels")
    assert html =~ "Subscribed"
  end

  test "reports subscription per channel, not once for the page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/channels")

    for channel <- ["whatsapp", "telegram"] do
      card = view |> element("section.channel-card", channel) |> render()
      assert card =~ "Subscribed"
    end

    refute has_element?(view, ".channels-header .conn-badge")
  end

  test "names the identifiers each channel reports", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/channels")

    telegram = view |> element("section.channel-card", "telegram") |> render()
    assert telegram =~ "chat.id"
    assert telegram =~ "from.id"

    whatsapp = view |> element("section.channel-card", "whatsapp") |> render()
    assert whatsapp =~ "from"
  end

  test "shows the identifier values a message arrived with", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/channels")

    :ok =
      Channel.handle_message(:telegram, %{
        "update_id" => 7,
        "message" => %{
          "chat" => %{"id" => -1_001_234_567_890},
          "from" => %{"id" => 42},
          "text" => "Posted from a group"
        }
      })

    card = view |> element("section.channel-card", "telegram") |> render()

    # Both values, under the names the channel documents.
    assert card =~ "chat.id"
    assert card =~ "-1001234567890"
    assert card =~ "from.id"
    assert card =~ "42"
  end

  test "names identifiers together rather than repeating a shared value", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/channels")

    # A private chat: Telegram reports the user's own id as both chat.id and
    # from.id, so the number should appear once under both names.
    :ok =
      Channel.handle_message(:telegram, %{
        "update_id" => 119_773_467,
        "message" => %{
          "chat" => %{"id" => 8_827_630_462},
          "from" => %{"id" => 8_827_630_462},
          "text" => "Hello from a private chat"
        }
      })

    card = view |> element("section.channel-card", "telegram") |> render()

    assert card =~ "chat.id · from.id"
    assert card =~ "8827630462"
    assert card =~ "update_id"
    assert card =~ "119773467"
  end

  test "links each channel to its API reference", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/channels")

    assert has_element?(view, ~s{#reference-telegram a[href^="https://core.telegram.org"]})
    assert has_element?(view, ~s{#reference-whatsapp a[href^="https://developers.facebook.com"]})

    # The module name moved out of the header and into the reference panel.
    assert has_element?(view, "#reference-telegram", "ChatAgent.Channel.Telegram")
  end

  describe "sending a reply" do
    setup %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/channels")

      :ok =
        Channel.handle_message(:telegram, %{
          "update_id" => 119_773_467,
          "message" => %{
            "chat" => %{"id" => 8_827_630_462},
            "from" => %{"id" => 8_827_630_462},
            "text" => "Hi, can you help me?"
          }
        })

      # The channel posts from the LiveView process, not the test process.
      Req.Test.allow(ChatAgent.Channel.Telegram, self(), view.pid)

      %{view: view}
    end

    test "addresses the conversation the newest message arrived on", %{view: view} do
      Req.Test.stub(ChatAgent.Channel.Telegram, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)

        assert payload["chat_id"] == "8827630462"
        assert payload["text"] == "On it, checking now"

        Req.Test.json(conn, %{"ok" => true, "result" => %{"message_id" => 1}})
      end)

      html =
        view
        |> form("#send-form-telegram", send: %{body: "On it, checking now"})
        |> render_submit()

      assert html =~ "Sent on telegram to 8827630462"
    end

    test "shows the reply in the conversation, marked as sent from here", %{view: view} do
      Req.Test.stub(ChatAgent.Channel.Telegram, fn conn ->
        Req.Test.json(conn, %{"ok" => true, "result" => %{"message_id" => 1}})
      end)

      view |> form("#send-form-telegram", send: %{body: "On it, checking now"}) |> render_submit()

      card = view |> element("section.channel-card", "telegram") |> render()

      assert card =~ "On it, checking now"
      assert card =~ "is-outbound"
      assert card =~ "sent from this dashboard"
      # Addressed to the conversation it was sent on.
      assert card =~ "8827630462"
    end

    test "keeps addressing the person who wrote in, not our own reply", %{view: view} do
      Req.Test.stub(ChatAgent.Channel.Telegram, fn conn ->
        Req.Test.json(conn, %{"ok" => true, "result" => %{"message_id" => 1}})
      end)

      view |> form("#send-form-telegram", send: %{body: "On it"}) |> render_submit()

      # The reply is now the newest message, but a further reply still goes to
      # the conversation rather than to ourselves.
      assert view |> element("#send-form-telegram .message-form-to") |> render() =~
               "chat.id · from.id"

      view |> form("#send-form-telegram", send: %{body: "And another"}) |> render_submit()

      assert view |> element("section.channel-card", "telegram") |> render() =~ "And another"
    end

    test "clears the composer once the message is away", %{view: view} do
      Req.Test.stub(ChatAgent.Channel.Telegram, fn conn ->
        Req.Test.json(conn, %{"ok" => true, "result" => %{"message_id" => 1}})
      end)

      form = form(view, "#send-form-telegram", send: %{body: "On it"})

      # Typing first, so the rendered value really holds something to clear.
      render_change(form)
      assert view |> element("#send-telegram-body") |> render() =~ ~s(value="On it")

      render_submit(form)

      assert view |> element("#send-telegram-body") |> render() =~ ~s(value="")
      refute view |> element("#send-telegram-body") |> render() =~ ~s(value="On it")
    end

    test "keeps what is typed when it could not be sent", %{view: view} do
      Req.Test.stub(ChatAgent.Channel.Telegram, fn conn ->
        Req.Test.json(conn, %{"ok" => false, "description" => "chat not found"})
      end)

      form = form(view, "#send-form-telegram", send: %{body: "Worth another try"})
      render_change(form)
      render_submit(form)

      # Nothing was delivered, so the text is still there to retry or edit.
      assert view |> element("#send-telegram-body") |> render() =~ ~s(value="Worth another try")
    end

    test "reports a failure the service answered with", %{view: view} do
      Req.Test.stub(ChatAgent.Channel.Telegram, fn conn ->
        Req.Test.json(conn, %{"ok" => false, "description" => "chat not found"})
      end)

      html = view |> form("#send-form-telegram", send: %{body: "On it"}) |> render_submit()

      assert html =~ "Could not send on telegram"
      assert html =~ "chat not found"
    end

    test "refuses an empty message rather than posting it", %{view: view} do
      # No stub: any request to the service fails the test.
      html = view |> form("#send-form-telegram", send: %{body: "   "}) |> render_submit()

      assert html =~ "Nothing to send on telegram"
    end

    test "refuses to send on a channel with no conversation yet", %{view: view} do
      html =
        render_submit(view, "send_message", %{
          "send" => %{"channel" => "whatsapp", "body" => "Hello"}
        })

      assert html =~ "No conversation on whatsapp to reply to yet"
    end

    test "survives a change event a disabled composer left the body out of", %{conn: conn} do
      # What a browser submits for a channel with no conversation yet: the
      # composer is disabled, so only the hidden channel field is serialised.
      {:ok, view, _html} = live(conn, ~p"/channels")

      html = render_change(view, "compose", %{"send" => %{"channel" => "whatsapp"}})

      assert html =~ "Nothing to reply to yet"
      assert render(view) =~ "send-form-whatsapp"
    end

    test "refuses to send a body that never arrived", %{view: view} do
      html = render_submit(view, "send_message", %{"send" => %{"channel" => "telegram"}})

      assert html =~ "Nothing to send on telegram"
    end

    test "ignores typing reported for a channel it does not know", %{view: view} do
      html =
        render_change(view, "compose", %{
          "send" => %{"channel" => "carrier_pigeon", "body" => "Hello"}
        })

      # Nothing to store it against, so the view is left as it was.
      refute html =~ "Hello"
    end

    test "refuses to send on a channel it does not know", %{view: view} do
      html =
        render_submit(view, "send_message", %{
          "send" => %{"channel" => "carrier_pigeon", "body" => "Hello"}
        })

      assert html =~ "Unknown channel"
    end
  end

  test "disables the composer until a conversation exists", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/channels")

    assert view |> element("#send-form-whatsapp button") |> render() =~ "disabled"
    assert view |> element("#send-form-whatsapp") |> render() =~ "Nothing to reply to yet"
  end

  test "gives each channel its own brand icon", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/channels")

    assert has_element?(view, ".channel-avatar.is-whatsapp svg")
    assert has_element?(view, ".channel-avatar.is-telegram svg")
  end

  test "carries the app brand and a three way theme toggle", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/channels")

    assert html =~ "ChatBot"
    refute html =~ "phoenixframework.org"

    for theme <- ~w(system light dark) do
      assert has_element?(view, ~s(.theme-toggle button[data-set-theme="#{theme}"]))
    end
  end

  test "appends a message received on a channel", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/channels")

    :ok =
      Channel.handle_message(:whatsapp, %{
        "from" => "1234567890",
        "id" => "msg_123",
        "text" => %{"body" => "Hello from WhatsApp"}
      })

    html = render(view)
    assert html =~ "Hello from WhatsApp"
    assert html =~ "1234567890"
  end

  test "keeps the newest message first in the DOM", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/channels")

    for {text, id} <- [{"older message", 1}, {"newer message", 2}] do
      :ok =
        Channel.handle_message(:telegram, %{
          "update_id" => id,
          "message" => %{"chat" => %{"id" => 1}, "from" => %{"id" => 1}, "text" => text}
        })
    end

    card = view |> element("section.channel-card", "telegram") |> render()

    # The list is laid out with flex-direction: column-reverse so the newest
    # message shows at the bottom, the way a chat client reads. That depends on
    # the newest being first in the DOM, so the order is asserted here rather
    # than left to the stylesheet alone.
    assert :binary.match(card, "newer message") < :binary.match(card, "older message")
  end

  test "keeps each channel's messages in its own card", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/channels")

    :ok =
      Channel.handle_message(:telegram, %{
        "update_id" => 7,
        "message" => %{"chat" => %{"id" => 123_456}, "text" => "Hello from Telegram"}
      })

    telegram_card = view |> element("section.channel-card", "telegram") |> render()
    assert telegram_card =~ "Hello from Telegram"

    whatsapp_card = view |> element("section.channel-card", "whatsapp") |> render()
    refute whatsapp_card =~ "Hello from Telegram"
    # A channel nothing arrived on shows an empty pane, and says so with its
    # own count rather than with a line of prose.
    refute whatsapp_card =~ "message-bubble"
  end
end
