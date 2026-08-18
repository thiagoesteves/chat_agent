defmodule ChatAgentWeb.WhatsappControllerTest do
  # Not async: pointing the whatsapp channel at the mock changes global
  # application config.
  use ChatAgentWeb.ConnCase, async: false

  import Mox

  setup :verify_on_exit!

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

  test "POST /webhook forwards each message to the whatsapp channel", %{conn: conn} do
    stub_whatsapp_channel()

    expect(ChatAgent.ChannelMock, :handle_message, fn message ->
      assert message == %{
               "from" => "1234567890",
               "id" => "msg_123",
               "text" => %{"body" => "Hello"}
             }

      :ok
    end)

    conn = post_webhook(conn, entry_with_messages([message("msg_123", "Hello")]))

    assert conn.status == 200
    assert conn.resp_body == "OK"
  end

  test "POST /webhook forwards every message in the envelope", %{conn: conn} do
    stub_whatsapp_channel()

    expect(ChatAgent.ChannelMock, :handle_message, 2, fn message ->
      assert message["id"] in ["msg_1", "msg_2"]
      :ok
    end)

    conn =
      post_webhook(conn, entry_with_messages([message("msg_1", "One"), message("msg_2", "Two")]))

    assert conn.status == 200
  end

  test "POST /webhook ignores a status change with no messages", %{conn: conn} do
    stub_whatsapp_channel()

    # No expectation: any call to the channel fails the test.
    payload = %{
      "object" => "whatsapp_business_account",
      "entry" => [%{"changes" => [%{"value" => %{"statuses" => [%{"id" => "msg_123"}]}}]}]
    }

    conn = post_webhook(conn, payload)

    assert conn.status == 200
  end

  test "POST /webhook ignores an entry with no changes", %{conn: conn} do
    stub_whatsapp_channel()

    conn = post_webhook(conn, %{"object" => "whatsapp_business_account", "entry" => [%{}]})

    assert conn.status == 200
  end

  test "POST /webhook ignores a change it does not recognise", %{conn: conn} do
    stub_whatsapp_channel()

    payload = %{
      "object" => "whatsapp_business_account",
      "entry" => [%{"changes" => [%{"value" => %{"contacts" => []}}]}]
    }

    conn = post_webhook(conn, payload)

    assert conn.status == 200
  end

  test "GET /webhook with a non-subscribe request returns 400", %{conn: conn} do
    conn = get(conn, ~p"/webhook", %{"hub.mode" => "unsubscribe"})

    assert conn.status == 400
    assert conn.resp_body == "Bad Request"
  end

  test "POST /webhook with unknown object returns 404", %{conn: conn} do
    conn = post_webhook(conn, %{"object" => "other"})

    assert conn.status == 404
    assert conn.resp_body == "Not Found"
  end

  defp post_webhook(conn, payload) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/webhook", Jason.encode!(payload))
  end

  defp entry_with_messages(messages) do
    %{
      "object" => "whatsapp_business_account",
      "entry" => [%{"changes" => [%{"value" => %{"messages" => messages}}]}]
    }
  end

  defp message(id, body) do
    %{"from" => "1234567890", "id" => id, "text" => %{"body" => body}}
  end

  defp stub_whatsapp_channel do
    configured = Application.get_env(:chat_agent, ChatAgent.Channel)

    on_exit(fn -> Application.put_env(:chat_agent, ChatAgent.Channel, configured) end)

    Application.put_env(:chat_agent, ChatAgent.Channel,
      adapters: Keyword.put(configured[:adapters], :whatsapp, ChatAgent.ChannelMock)
    )
  end
end
