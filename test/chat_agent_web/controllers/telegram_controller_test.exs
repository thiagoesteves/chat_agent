defmodule ChatAgentWeb.TelegramControllerTest do
  use ChatAgentWeb.ConnCase, async: true

  test "POST /telegram/webhook receives a message", %{conn: conn} do
    payload = %{
      "update_id" => 1,
      "message" => %{
        "chat" => %{"id" => 123_456},
        "text" => "Hello"
      }
    }

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-telegram-bot-api-secret-token", "test_telegram_webhook_secret")
      |> post(~p"/telegram/webhook", Jason.encode!(payload))

    assert conn.status == 200
    assert conn.resp_body == "OK"
  end

  test "POST /telegram/webhook with wrong secret returns 403", %{conn: conn} do
    payload = %{
      "update_id" => 1,
      "message" => %{
        "chat" => %{"id" => 123_456},
        "text" => "Hello"
      }
    }

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-telegram-bot-api-secret-token", "wrong")
      |> post(~p"/telegram/webhook", Jason.encode!(payload))

    assert conn.status == 403
    assert conn.resp_body == "Forbidden"
  end

  test "POST /telegram/webhook with missing update_id returns 400", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-telegram-bot-api-secret-token", "test_telegram_webhook_secret")
      |> post(~p"/telegram/webhook", Jason.encode!(%{}))

    assert conn.status == 400
    assert conn.resp_body == "Bad Request"
  end
end
