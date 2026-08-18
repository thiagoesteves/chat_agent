defmodule ChatAgent.Channel.Whatsapp do
  @moduledoc """
  WhatsApp channel, spoken over the WhatsApp Cloud API.

  Inbound, it receives one entry of the `messages` list a webhook delivers,
  after `ChatAgentWeb.WhatsappController` has unwrapped the entry/change
  envelope. Outbound, it posts text messages to the Cloud API.
  """

  @behaviour ChatAgent.Channel.Adapter

  alias ChatAgent.Channel.Message

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

    {:ok, Message.new(id: message["id"], sender: phone, text: body)}
  end

  def handle_message(message) do
    Logger.info(%{
      what: "whatsapp_event_received",
      message: message
    })

    :ok
  end

  @impl true
  def authenticate(_conn) do
    # The Cloud API signs the raw body with X-Hub-Signature-256. Verifying it
    # needs the unparsed body, which this endpoint does not retain yet, so
    # inbound requests are currently accepted on the strength of the URL alone.
    :ok
  end

  @impl true
  def inbound_messages(%{"object" => "whatsapp_business_account", "entry" => entries}) do
    {:ok, Enum.flat_map(entries, &messages_in_entry/1)}
  end

  def inbound_messages(_params), do: {:error, :not_found}

  @impl true
  def verify_subscription(%{
        "hub.mode" => "subscribe",
        "hub.verify_token" => token,
        "hub.challenge" => challenge
      }) do
    if token == get_config(:whatsapp_verify_token, nil) do
      {:ok, challenge}
    else
      {:error, :forbidden}
    end
  end

  def verify_subscription(_params), do: {:error, :bad_request}

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

  # A webhook batches changes behind an entry/change envelope, and only a
  # change carrying `messages` holds anything inbound. Statuses and anything
  # unrecognised are ignored rather than raising, since the service retries a
  # failed webhook response.
  defp messages_in_entry(%{"changes" => changes}),
    do: Enum.flat_map(changes, &messages_in_change/1)

  defp messages_in_entry(_entry), do: []

  defp messages_in_change(%{"value" => %{"messages" => messages}}), do: messages
  defp messages_in_change(_change), do: []

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
