defmodule ChatAgent.Channel.WhatsappTest do
  use ExUnit.Case, async: true

  alias ChatAgent.Channel.Message
  alias ChatAgent.Channel.Whatsapp

  describe "handle_message/1" do
    test "processes a text message" do
      message = %{
        "from" => "1234567890",
        "id" => "msg_123",
        "text" => %{"body" => "Hello"}
      }

      assert {:ok, %Message{} = parsed} = Whatsapp.handle_message(message)
      assert parsed.id == "msg_123"
      assert parsed.sender == "1234567890"
      # One to one only, so the reply address is the sender.
      assert parsed.conversation == "1234567890"
      assert parsed.identifiers == [{"from", "1234567890"}, {"id", "msg_123"}]
      assert parsed.text == "Hello"
      assert %DateTime{} = parsed.received_at
      # The facade stamps the channel when it broadcasts.
      assert parsed.channel == nil
    end

    test "processes an unknown event" do
      assert :ok = Whatsapp.handle_message(%{"statuses" => [%{"id" => "msg_123"}]})
    end
  end

  describe "send_message/2" do
    test "posts a text message to the Cloud API" do
      Req.Test.stub(Whatsapp, fn conn ->
        assert conn.method == "POST"
        Req.Test.json(conn, %{"messages" => [%{"id" => "msg_123"}]})
      end)

      assert :ok = Whatsapp.send_message("1234567890", "Hello")
    end

    test "reports an error described by the Cloud API" do
      Req.Test.stub(Whatsapp, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => %{"message" => "Invalid phone number"}})
      end)

      assert {:error, {:whatsapp_error, 400, %{"message" => "Invalid phone number"}}} =
               Whatsapp.send_message("not-a-number", "Hello")
    end

    test "reports an unexpected status" do
      Req.Test.stub(Whatsapp, fn conn ->
        Plug.Conn.send_resp(conn, 502, "Bad Gateway")
      end)

      assert {:error, {:http_error, 502}} = Whatsapp.send_message("1234567890", "Hello")
    end

    test "reports a transport error" do
      Req.Test.stub(Whatsapp, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Whatsapp.send_message("1234567890", "Hello")
    end
  end

  describe "reference/0" do
    test "names the identifiers and where they are documented" do
      reference = Whatsapp.reference()

      assert reference.url =~ "developers.facebook.com"
      assert Enum.any?(reference.fields, &match?({"from", _}, &1))
    end
  end

  describe "authenticate/1" do
    test "accepts the request, since the URL is what identifies the channel today" do
      assert :ok = Whatsapp.authenticate(%Plug.Conn{})
    end
  end

  describe "inbound_messages/1" do
    test "flattens every message out of the entry and change envelope" do
      params = %{
        "object" => "whatsapp_business_account",
        "entry" => [
          %{"changes" => [%{"value" => %{"messages" => [%{"id" => "a"}, %{"id" => "b"}]}}]},
          %{"changes" => [%{"value" => %{"messages" => [%{"id" => "c"}]}}]}
        ]
      }

      assert {:ok, [%{"id" => "a"}, %{"id" => "b"}, %{"id" => "c"}]} =
               Whatsapp.inbound_messages(params)
    end

    test "yields nothing for changes that carry no messages" do
      params = %{
        "object" => "whatsapp_business_account",
        "entry" => [
          %{"changes" => [%{"value" => %{"statuses" => [%{"id" => "a"}]}}]},
          %{"changes" => [%{"value" => %{}}]},
          %{}
        ]
      }

      assert {:ok, []} = Whatsapp.inbound_messages(params)
    end

    test "rejects a body that is not a WhatsApp webhook" do
      assert {:error, :not_found} = Whatsapp.inbound_messages(%{"object" => "other"})
    end
  end

  describe "verify_subscription/1" do
    test "returns the challenge when the token matches" do
      assert {:ok, "challenge_123"} =
               Whatsapp.verify_subscription(%{
                 "hub.mode" => "subscribe",
                 "hub.verify_token" => "test_verify_token",
                 "hub.challenge" => "challenge_123"
               })
    end

    test "rejects a mismatched token" do
      assert {:error, :forbidden} =
               Whatsapp.verify_subscription(%{
                 "hub.mode" => "subscribe",
                 "hub.verify_token" => "wrong",
                 "hub.challenge" => "challenge_123"
               })
    end

    test "rejects anything that is not a subscribe handshake" do
      assert {:error, :bad_request} = Whatsapp.verify_subscription(%{"hub.mode" => "unsubscribe"})
    end
  end
end
