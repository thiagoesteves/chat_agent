defmodule ChatAgentWeb.TelegramControllerTest do
  # Not async: pointing the telegram channel at the mock changes global
  # application config.
  use ChatAgentWeb.ConnCase, async: false

  import Mox

  setup :verify_on_exit!

  test "POST /telegram/webhook forwards the update to the telegram channel", %{conn: conn} do
    stub_telegram_channel()

    update = %{
      "update_id" => 1,
      "message" => %{"chat" => %{"id" => 123_456}, "text" => "Hello"}
    }

    expect(ChatAgent.ChannelMock, :handle_message, fn payload ->
      assert payload == update
      :ok
    end)

    conn = post_webhook(conn, update, "test_telegram_webhook_secret")

    assert conn.status == 200
    assert conn.resp_body == "OK"
  end

  test "POST /telegram/webhook with wrong secret returns 403", %{conn: conn} do
    stub_telegram_channel()

    # No expectation: a rejected update must never reach the channel.
    update = %{
      "update_id" => 1,
      "message" => %{"chat" => %{"id" => 123_456}, "text" => "Hello"}
    }

    conn = post_webhook(conn, update, "wrong")

    assert conn.status == 403
    assert conn.resp_body == "Forbidden"
  end

  test "POST /telegram/webhook with missing update_id returns 400", %{conn: conn} do
    stub_telegram_channel()

    conn = post_webhook(conn, %{}, "test_telegram_webhook_secret")

    assert conn.status == 400
    assert conn.resp_body == "Bad Request"
  end

  test "POST /telegram/webhook accepts any request when no secret is configured", %{conn: conn} do
    stub_telegram_channel()
    configured_secret = Application.get_env(:chat_agent, :telegram_webhook_secret)

    on_exit(fn ->
      Application.put_env(:chat_agent, :telegram_webhook_secret, configured_secret)
    end)

    Application.put_env(:chat_agent, :telegram_webhook_secret, nil)

    expect(ChatAgent.ChannelMock, :handle_message, fn _update -> :ok end)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/telegram/webhook", Jason.encode!(%{"update_id" => 1}))

    assert conn.status == 200
  end

  defp post_webhook(conn, payload, secret) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-telegram-bot-api-secret-token", secret)
    |> post(~p"/telegram/webhook", Jason.encode!(payload))
  end

  defp stub_telegram_channel do
    configured = Application.get_env(:chat_agent, ChatAgent.Channel)

    on_exit(fn -> Application.put_env(:chat_agent, ChatAgent.Channel, configured) end)

    Application.put_env(:chat_agent, ChatAgent.Channel,
      adapters: Keyword.put(configured[:adapters], :telegram, ChatAgent.ChannelMock)
    )
  end
end
