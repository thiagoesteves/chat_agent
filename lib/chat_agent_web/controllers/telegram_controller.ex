defmodule ChatAgentWeb.TelegramController do
  use ChatAgentWeb, :controller

  def receive(conn, %{"update_id" => _} = update) do
    if valid_secret?(conn) do
      ChatAgent.TelegramMessageHandler.handle(update)
      send_resp(conn, 200, "OK")
    else
      send_resp(conn, 403, "Forbidden")
    end
  end

  def receive(conn, _params) do
    send_resp(conn, 400, "Bad Request")
  end

  defp valid_secret?(conn) do
    case Application.get_env(:chat_agent, :telegram_webhook_secret) do
      nil ->
        true

      expected ->
        [header] = get_req_header(conn, "x-telegram-bot-api-secret-token")
        header == expected
    end
  end
end
