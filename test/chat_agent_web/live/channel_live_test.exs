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
