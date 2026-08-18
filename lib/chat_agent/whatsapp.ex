defmodule ChatAgent.Whatsapp do
  @moduledoc """
  Minimal WhatsApp Cloud API client for sending messages.
  """

  def send_text(to, body) do
    phone_number_id = get_config!(:whatsapp_phone_number_id)
    access_token = get_config!(:whatsapp_access_token)
    api_version = get_config(:whatsapp_api_version, "v20.0")

    url = "https://graph.facebook.com/#{api_version}/#{phone_number_id}/messages"

    payload = %{
      messaging_product: "whatsapp",
      recipient_type: "individual",
      to: to,
      type: "text",
      text: %{preview_url: false, body: body}
    }

    options = [
      headers: [
        authorization: "Bearer #{access_token}",
        content_type: "application/json"
      ],
      json: payload
    ]

    req_options = Application.get_env(:chat_agent, :whatsapp_req_options, [])

    Req.post!(url, Keyword.merge(options, req_options))
  end

  defp get_config!(key) do
    Application.fetch_env!(:chat_agent, key)
  end

  defp get_config(key, default) do
    Application.get_env(:chat_agent, key, default)
  end
end
