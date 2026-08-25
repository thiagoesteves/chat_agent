defmodule ChatAgentWeb.TelegramControllerTest do
  # Not async: pointing the channel at the mock changes global application config.
  use ChatAgentWeb.ConnCase, async: false

  import Mox

  alias ChatAgent.Channel
  alias ChatAgent.ChannelMock

  setup :verify_on_exit!

  test "POST /telegram/webhook forwards the update to the channel", %{conn: conn} do
    stub_channel()
    update = %{"update_id" => 1, "message" => %{"chat" => %{"id" => 123_456}, "text" => "Hello"}}

    expect(ChannelMock, :handle_message, fn payload ->
      assert payload == update
      :ok
    end)

    conn = post_webhook(conn, update, "test_telegram_webhook_secret")

    assert conn.status == 200
    assert conn.resp_body == "OK"
  end

  test "POST /telegram/webhook rejects a wrong secret before the payload is read", %{conn: conn} do
    stub_channel()

    # No expectation: a rejected update must never reach the channel.
    update = %{"update_id" => 1, "message" => %{"chat" => %{"id" => 123_456}, "text" => "Hello"}}

    conn = post_webhook(conn, update, "wrong")

    assert conn.status == 403
    assert conn.resp_body == "Forbidden"
  end

  test "POST /telegram/webhook answers 400 for a body that is not an update", %{conn: conn} do
    conn = post_webhook(conn, %{}, "test_telegram_webhook_secret")

    assert conn.status == 400
    assert conn.resp_body == "Bad Request"
  end

  test "POST /telegram/webhook has no handshake route", %{conn: conn} do
    assert get(conn, "/telegram/webhook?token=test_telegram_webhook_token", %{}).status == 404
  end

  test "POST /telegram/webhook rejects a wrong URL token before the secret is checked",
       %{conn: conn} do
    stub_channel()

    # No expectation: the update must never reach the channel. The header
    # secret is the right one, so it is the token in the URL being refused.
    update = %{"update_id" => 1, "message" => %{"chat" => %{"id" => 123_456}, "text" => "Hello"}}

    conn = post_webhook(conn, update, "test_telegram_webhook_secret", "wrong")

    assert conn.status == 403
    assert conn.resp_body == "Forbidden"
  end

  test "POST /telegram/webhook rejects a request carrying no token at all", %{conn: conn} do
    stub_channel()

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-telegram-bot-api-secret-token", "test_telegram_webhook_secret")
      |> post("/telegram/webhook", Jason.encode!(%{"update_id" => 1}))

    assert conn.status == 403
    assert conn.resp_body == "Forbidden"
  end

  defp post_webhook(conn, payload, secret, token \\ "test_telegram_webhook_token") do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-telegram-bot-api-secret-token", secret)
    |> post("/telegram/webhook?token=#{token}", Jason.encode!(payload))
  end

  defp stub_channel do
    configured = Application.get_env(:chat_agent, Channel)

    on_exit(fn -> Application.put_env(:chat_agent, Channel, configured) end)

    Application.put_env(:chat_agent, Channel,
      adapters: Keyword.put(configured[:adapters], :telegram, ChannelMock)
    )
  end
end
