defmodule ChatAgent.Channel.Whatsapp do
  @moduledoc """
  WhatsApp channel, spoken over the WhatsApp Cloud API.

  Inbound, it receives one entry of the `messages` list a webhook delivers,
  after `ChatAgentWeb.WhatsappController` has unwrapped the entry/change
  envelope. Outbound, it posts text messages to the Cloud API.
  """

  @behaviour ChatAgent.Channel.Adapter

  require Logger

  ### ==========================================================================
  ### Callback functions
  ### ==========================================================================

  @impl true
  def handle_message(%{"from" => phone, "text" => %{"body" => body}} = message) do
    Logger.info(%{
      what: "whatsapp_message_received",
      from: phone,
      body: body,
      message_id: message["id"]
    })

    :ok
  end

  def handle_message(message) do
    Logger.info(%{
      what: "whatsapp_event_received",
      message: message
    })

    :ok
  end

  @impl true
  def send_message(to, body) do
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

    url
    |> Req.post(Keyword.merge(options, req_options))
    |> interpret_response()
  end

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================

  # The Cloud API signals failure with the HTTP status and describes it in an
  # `error` object, so the status is what decides the outcome here.
  defp interpret_response({:ok, %Req.Response{status: status}}) when status in 200..299, do: :ok

  defp interpret_response({:ok, %Req.Response{status: status, body: %{"error" => error}}}),
    do: {:error, {:whatsapp_error, status, error}}

  defp interpret_response({:ok, %Req.Response{status: status}}),
    do: {:error, {:http_error, status}}

  defp interpret_response({:error, exception}), do: {:error, exception}

  defp get_config!(key), do: Application.fetch_env!(:chat_agent, key)

  defp get_config(key, default), do: Application.get_env(:chat_agent, key, default)
end
