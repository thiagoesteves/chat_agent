defmodule ChatAgent.WhatsappTest do
  use ExUnit.Case, async: true

  alias ChatAgent.Whatsapp

  test "send_text/2 posts a WhatsApp text message" do
    Req.Test.stub(Whatsapp, fn conn ->
      assert conn.method == "POST"
      Req.Test.json(conn, %{"messages" => [%{"id" => "msg_123"}]})
    end)

    assert %{status: 200} = Whatsapp.send_text("1234567890", "Hello")
  end
end
