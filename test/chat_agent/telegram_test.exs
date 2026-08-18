defmodule ChatAgent.TelegramTest do
  use ExUnit.Case, async: true

  alias ChatAgent.Telegram

  test "send_text/2 posts a Telegram text message" do
    Req.Test.stub(Telegram, fn conn ->
      assert conn.method == "POST"
      Req.Test.json(conn, %{"ok" => true, "result" => %{"message_id" => 1}})
    end)

    assert %{status: 200} = Telegram.send_text(123_456, "Hello")
  end
end
