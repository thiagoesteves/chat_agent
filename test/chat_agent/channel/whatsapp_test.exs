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
end
