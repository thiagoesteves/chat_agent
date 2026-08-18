defmodule ChatAgentWeb.WebhookControllerTest do
  # Not async: pointing a channel at the mock changes global application config.
  use ChatAgentWeb.ConnCase, async: false

  import Mox

  alias ChatAgent.Channel
  alias ChatAgent.ChannelMock

  setup :verify_on_exit!

  describe "GET /:channel/webhook" do
    test "answers the WhatsApp subscription handshake", %{conn: conn} do
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

    test "has no handshake route for a channel that performs none", %{conn: conn} do
      assert get(conn, "/telegram/webhook", %{}).status == 404
    end

    test "has no route for an unknown channel", %{conn: conn} do
      assert get(conn, "/carrier_pigeon/webhook", %{}).status == 404
    end
  end

  describe "POST /whatsapp/webhook" do
    test "forwards each message in the envelope to the channel", %{conn: conn} do
      stub_channel(:whatsapp)

      expect(ChannelMock, :inbound_messages, fn params ->
        Channel.Whatsapp.inbound_messages(params)
      end)

      expect(ChannelMock, :authenticate, fn _conn -> :ok end)

      expect(ChannelMock, :handle_message, 2, fn message ->
        assert message["id"] in ["msg_1", "msg_2"]
        :ok
      end)

      conn =
        post_webhook(conn, "whatsapp", %{
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
      # No handle_message expectation: any call to the channel fails the test.
      conn =
        post_webhook(conn, "whatsapp", %{
          "object" => "whatsapp_business_account",
          "entry" => [%{"changes" => [%{"value" => %{"statuses" => [%{"id" => "msg_1"}]}}]}]
        })

      assert conn.status == 200
    end

    test "ignores an entry with no changes", %{conn: conn} do
      conn =
        post_webhook(conn, "whatsapp", %{
          "object" => "whatsapp_business_account",
          "entry" => [%{}]
        })

      assert conn.status == 200
    end

    test "answers 404 for a body that is not a WhatsApp webhook", %{conn: conn} do
      conn = post_webhook(conn, "whatsapp", %{"object" => "other"})

      assert conn.status == 404
      assert conn.resp_body == "Not Found"
    end
  end

  describe "POST /telegram/webhook" do
    test "forwards the update to the channel", %{conn: conn} do
      stub_channel(:telegram)
      update = %{"update_id" => 1, "message" => %{"chat" => %{"id" => 1}, "text" => "Hi"}}

      expect(ChannelMock, :authenticate, fn _conn -> :ok end)
      expect(ChannelMock, :inbound_messages, fn params -> {:ok, [params]} end)

      expect(ChannelMock, :handle_message, fn payload ->
        assert payload["update_id"] == 1
        :ok
      end)

      conn = post_webhook(conn, "telegram", update, "test_telegram_webhook_secret")

      assert conn.status == 200
      assert conn.resp_body == "OK"
    end

    test "rejects a wrong secret before the payload is looked at", %{conn: conn} do
      update = %{"update_id" => 1, "message" => %{"chat" => %{"id" => 1}, "text" => "Hi"}}

      conn = post_webhook(conn, "telegram", update, "wrong")

      assert conn.status == 403
      assert conn.resp_body == "Forbidden"
    end

    test "answers 400 for a body that is not an update", %{conn: conn} do
      conn = post_webhook(conn, "telegram", %{}, "test_telegram_webhook_secret")

      assert conn.status == 400
      assert conn.resp_body == "Bad Request"
    end
  end

  test "has no route for an unknown channel", %{conn: conn} do
    assert post_webhook(conn, "carrier_pigeon", %{"update_id" => 1}).status == 404
  end

  test "answers 404 when a route outlives the channel it points at", %{conn: conn} do
    # Routes are fixed at compile time while the adapter list is read at call
    # time, so a channel removed from configuration must not 500.
    configured = Application.get_env(:chat_agent, Channel)
    on_exit(fn -> Application.put_env(:chat_agent, Channel, configured) end)

    Application.put_env(:chat_agent, Channel,
      adapters: Keyword.delete(configured[:adapters], :whatsapp)
    )

    assert post_webhook(conn, "whatsapp", %{"object" => "whatsapp_business_account"}).status ==
             404

    assert get(conn, "/whatsapp/webhook", %{"hub.mode" => "subscribe"}).status == 404
  end

  defp post_webhook(conn, channel, payload, secret \\ nil) do
    conn
    |> put_req_header("content-type", "application/json")
    |> then(fn conn ->
      if secret,
        do: put_req_header(conn, "x-telegram-bot-api-secret-token", secret),
        else: conn
    end)
    |> post("/#{channel}/webhook", Jason.encode!(payload))
  end

  defp message(id, body) do
    %{"from" => "1234567890", "id" => id, "text" => %{"body" => body}}
  end

  defp stub_channel(channel) do
    configured = Application.get_env(:chat_agent, Channel)

    on_exit(fn -> Application.put_env(:chat_agent, Channel, configured) end)

    Application.put_env(:chat_agent, Channel,
      adapters: Keyword.put(configured[:adapters], channel, ChannelMock)
    )
  end
end
