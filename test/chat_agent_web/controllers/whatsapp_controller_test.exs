defmodule ChatAgentWeb.WhatsappControllerTest do
  use ChatAgentWeb.ConnCase, async: true

  test "GET /webhook verifies the subscription", %{conn: conn} do
    params = %{
      "hub.mode" => "subscribe",
      "hub.verify_token" => "test_verify_token",
      "hub.challenge" => "challenge_123"
    }

    conn = get(conn, ~p"/webhook", params)
    assert conn.status == 200
    assert conn.resp_body == "challenge_123"
  end

  test "GET /webhook with wrong token returns 403", %{conn: conn} do
    params = %{
      "hub.mode" => "subscribe",
      "hub.verify_token" => "wrong",
      "hub.challenge" => "challenge_123"
    }

    conn = get(conn, ~p"/webhook", params)
    assert conn.status == 403
    assert conn.resp_body == "Forbidden"
  end

  test "POST /webhook receives a message", %{conn: conn} do
    payload = %{
      "object" => "whatsapp_business_account",
      "entry" => [
        %{
          "changes" => [
            %{
              "value" => %{
                "messages" => [
                  %{
                    "from" => "1234567890",
                    "id" => "msg_123",
                    "text" => %{"body" => "Hello"}
                  }
                ]
              }
            }
          ]
        }
      ]
    }

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/webhook", Jason.encode!(payload))

    assert conn.status == 200
    assert conn.resp_body == "OK"
  end

  test "POST /webhook with unknown object returns 404", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/webhook", Jason.encode!(%{"object" => "other"}))

    assert conn.status == 404
    assert conn.resp_body == "Not Found"
  end
end
