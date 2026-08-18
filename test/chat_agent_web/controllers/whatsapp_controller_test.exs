defmodule ChatAgentWeb.WhatsappControllerTest do
  # Not async: pointing the channel at the mock changes global application config.
  use ChatAgentWeb.ConnCase, async: false

  import Mox

  alias ChatAgent.Channel
  alias ChatAgent.ChannelMock

  setup :verify_on_exit!

  describe "GET /whatsapp/webhook" do
    test "answers the subscription handshake", %{conn: conn} do
      conn =
        get(conn, ~p"/whatsapp/webhook", %{
          "hub.mode" => "subscribe",
          "hub.verify_token" => "test_verify_token",
          "hub.challenge" => "challenge_123"
        })

      assert conn.status == 200
      assert conn.resp_body == "challenge_123"
    end

    test "rejects a handshake with the wrong token", %{conn: conn} do
      conn =
        get(conn, ~p"/whatsapp/webhook", %{
          "hub.mode" => "subscribe",
          "hub.verify_token" => "wrong",
          "hub.challenge" => "challenge_123"
        })

      assert conn.status == 403
      assert conn.resp_body == "Forbidden"
    end

    test "rejects a request that is not a handshake", %{conn: conn} do
      conn = get(conn, ~p"/whatsapp/webhook", %{"hub.mode" => "unsubscribe"})

      assert conn.status == 400
      assert conn.resp_body == "Bad Request"
    end
  end

  describe "POST /whatsapp/webhook" do
    test "forwards every message in the envelope to the channel", %{conn: conn} do
      stub_channel()

      expect(ChannelMock, :handle_message, 2, fn message ->
        assert message["id"] in ["msg_1", "msg_2"]
        :ok
      end)

      conn =
        post_webhook(conn, %{
          "object" => "whatsapp_business_account",
          "entry" => [
            %{
              "changes" => [
                %{"value" => %{"messages" => [message("msg_1", "One"), message("msg_2", "Two")]}}
              ]
            }
          ]
        })

      assert conn.status == 200
      assert conn.resp_body == "OK"
    end

    test "ignores a status change carrying no messages", %{conn: conn} do
      stub_channel()

      # No expectation: any call to the channel fails the test.
      conn =
        post_webhook(conn, %{
          "object" => "whatsapp_business_account",
          "entry" => [%{"changes" => [%{"value" => %{"statuses" => [%{"id" => "msg_1"}]}}]}]
        })

      assert conn.status == 200
    end

    test "ignores an entry with no changes", %{conn: conn} do
      stub_channel()

      conn = post_webhook(conn, %{"object" => "whatsapp_business_account", "entry" => [%{}]})

      assert conn.status == 200
    end

    test "answers 404 for a body that is not a WhatsApp webhook", %{conn: conn} do
      conn = post_webhook(conn, %{"object" => "other"})

      assert conn.status == 404
      assert conn.resp_body == "Not Found"
    end
  end

  defp post_webhook(conn, payload) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/whatsapp/webhook", Jason.encode!(payload))
  end

  defp message(id, body) do
    %{"from" => "1234567890", "id" => id, "text" => %{"body" => body}}
  end

  defp stub_channel do
    configured = Application.get_env(:chat_agent, Channel)

    on_exit(fn -> Application.put_env(:chat_agent, Channel, configured) end)

    Application.put_env(:chat_agent, Channel,
      adapters: Keyword.put(configured[:adapters], :whatsapp, ChannelMock)
    )
  end
end
