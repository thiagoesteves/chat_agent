defmodule ChatAgentWeb.ChannelLiveTest do
  use ChatAgentWeb.ConnCase, async: true

  alias ChatAgent.Channel

  test "lists every configured channel", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/channels")

    assert html =~ "whatsapp"
    assert html =~ "ChatAgent.Channel.Whatsapp"
    assert html =~ "telegram"
    assert html =~ "ChatAgent.Channel.Telegram"
  end

  test "shows an empty state naming the topic it waits on", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/channels")

    assert html =~ "Waiting for messages on"
    assert html =~ "channel:whatsapp"
    assert html =~ "channel:telegram"
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
    assert whatsapp_card =~ "Waiting for messages"
  end
end
