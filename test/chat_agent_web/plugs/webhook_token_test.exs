defmodule ChatAgentWeb.Plugs.WebhookTokenTest do
  use ChatAgentWeb.ConnCase, async: true

  import ExUnit.CaptureLog

  alias ChatAgentWeb.Plugs.WebhookToken

  describe "init/1" do
    test "keeps the channel the route fixed" do
      assert WebhookToken.init(channel: :telegram) == :telegram
    end

    test "refuses to be installed without one, since it would guard nothing" do
      assert_raise KeyError, fn -> WebhookToken.init([]) end
    end
  end

  describe "call/2" do
    test "lets a request carrying the channel's token through", %{conn: conn} do
      conn = call(conn, "/telegram/webhook?token=test_telegram_webhook_token", :telegram)

      refute conn.halted
      assert conn.status == nil
    end

    test "takes the token back out, so it is never handed on as payload", %{conn: conn} do
      conn = call(conn, "/telegram/webhook?token=test_telegram_webhook_token", :telegram)

      refute Map.has_key?(conn.params, "token")
      refute Map.has_key?(conn.query_params, "token")
    end

    test "leaves every other parameter alone", %{conn: conn} do
      conn =
        call(
          conn,
          "/whatsapp/webhook?token=test_whatsapp_webhook_token&hub.challenge=abc",
          :whatsapp
        )

      refute conn.halted
      assert conn.params["hub.challenge"] == "abc"
    end

    test "refuses a wrong token with 403 and nothing else", %{conn: conn} do
      conn = call(conn, "/telegram/webhook?token=wrong", :telegram)

      assert conn.halted
      assert conn.status == 403
      assert conn.resp_body == "Forbidden"
    end

    test "refuses a request with no token at all", %{conn: conn} do
      conn = call(conn, "/telegram/webhook", :telegram)

      assert conn.halted
      assert conn.status == 403
    end

    test "refuses another channel's token, so one URL does not open another", %{conn: conn} do
      conn = call(conn, "/telegram/webhook?token=test_whatsapp_webhook_token", :telegram)

      assert conn.halted
      assert conn.status == 403
    end

    test "logs a refusal without writing down what was presented", %{conn: conn} do
      logged =
        capture_log(fn ->
          call(conn, "/telegram/webhook?token=hunter2", :telegram)
        end)

      assert logged =~ "webhook_token_rejected"
      assert logged =~ "telegram"
      refute logged =~ "hunter2"
    end
  end

  defp call(_conn, path, channel) do
    :post
    |> Phoenix.ConnTest.build_conn(path)
    |> WebhookToken.call(WebhookToken.init(channel: channel))
  end
end
