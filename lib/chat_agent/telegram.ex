defmodule ChatAgent.Telegram do
  @moduledoc """
  Minimal Telegram Bot API client for sending messages.
  """

  def send_text(chat_id, text) do
    bot_token = get_config!(:telegram_bot_token)

    url = "https://api.telegram.org/bot#{bot_token}/sendMessage"

    payload = %{
      chat_id: chat_id,
      text: text
    }

    options = [
      headers: [content_type: "application/json"],
      json: payload
    ]

    req_options = Application.get_env(:chat_agent, :telegram_req_options, [])

    Req.post!(url, Keyword.merge(options, req_options))
  end

  defp get_config!(key) do
    Application.fetch_env!(:chat_agent, key)
  end
end
