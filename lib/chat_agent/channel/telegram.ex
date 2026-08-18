defmodule ChatAgent.Channel.Telegram do
  @moduledoc """
  Telegram channel, spoken over the Telegram Bot API.

  Inbound, it receives a whole update object, which is the unit the Telegram
  webhook posts. Outbound, it posts text messages to the Bot API.
  """

  @behaviour ChatAgent.Channel.Adapter

  alias ChatAgent.Channel.Message

  require Logger

  ### ==========================================================================
  ### Callback functions
  ### ==========================================================================

  @impl true
  def reference do
    %{
      url: "https://core.telegram.org/bots/api#message",
      fields: [
        {"chat.id",
         "The conversation, and the value sendMessage takes to reply. Positive for a " <>
           "private chat, where it equals the user's own id, negative for a group or channel."},
        {"from.id",
         "Who sent the message. Equal to chat.id in a private chat, but a person inside " <>
           "the group otherwise. Absent on channel posts."},
        {"update_id",
         "The webhook delivery, not the message. Per bot and sequential, which is what " <>
           "makes it useful for ignoring a repeated delivery, though it restarts from a " <>
           "random number after a week with no updates."}
      ]
    }
  end

  @impl true
  def handle_message(
        %{
          "message" =>
            %{
              "chat" => %{"id" => chat_id},
              "text" => text
            } = message
        } = update
      ) do
    # `from` names the person, `chat` names the conversation. They agree in a
    # private chat, where the chat id is the user's own id, and diverge in a
    # group, so a reply must use the chat.
    from_id = get_in(message, ["from", "id"])

    Logger.info(%{
      what: "telegram_message_received",
      chat_id: chat_id,
      from_id: from_id,
      text: text,
      update_id: update["update_id"]
    })

    {:ok,
     Message.new(
       id: to_string(update["update_id"]),
       sender: to_string(from_id || chat_id),
       conversation: to_string(chat_id),
       identifiers: identifiers(update["update_id"], chat_id, from_id),
       text: text
     )}
  end

  def handle_message(update) do
    Logger.info(%{
      what: "telegram_update_received",
      update: update
    })

    :ok
  end

  @impl true
  def authenticate(conn) do
    case Application.get_env(:chat_agent, :telegram_webhook_secret) do
      nil ->
        :ok

      expected ->
        if Plug.Conn.get_req_header(conn, "x-telegram-bot-api-secret-token") == [expected] do
          :ok
        else
          {:error, :forbidden}
        end
    end
  end

  @impl true
  def inbound_messages(%{"update_id" => _} = update), do: {:ok, [update]}
  def inbound_messages(_params), do: {:error, :bad_request}

  @impl true
  def verify_subscription(_params) do
    # The Bot API sets its webhook over the API and performs no handshake.
    {:error, :not_found}
  end

  @impl true
  def send_message(chat_id, body) do
    bot_token = get_config!(:telegram_bot_token)

    url = "https://api.telegram.org/bot#{bot_token}/sendMessage"

    payload = %{
      chat_id: chat_id,
      text: body
    }

    options = [
      headers: [content_type: "application/json"],
      json: payload
    ]

    req_options = Application.get_env(:chat_agent, :telegram_req_options, [])

    url
    |> Req.post(Keyword.merge(options, req_options))
    |> interpret_response()
  end

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================

  # Report only what the payload carried. A channel post has no `from`, and
  # printing the chat id under that name would show a value that never arrived.
  defp identifiers(update_id, chat_id, from_id) do
    from = if from_id, do: [{"from.id", to_string(from_id)}], else: []

    [{"chat.id", to_string(chat_id)}] ++ from ++ [{"update_id", to_string(update_id)}]
  end

  # The Bot API answers 200 with `"ok" => false` for logical failures, so the
  # body decides the outcome rather than the status alone.
  defp interpret_response({:ok, %Req.Response{body: %{"ok" => true}}}), do: :ok

  defp interpret_response({:ok, %Req.Response{body: %{"description" => description}}}),
    do: {:error, {:telegram_error, description}}

  defp interpret_response({:ok, %Req.Response{status: status}}),
    do: {:error, {:http_error, status}}

  defp interpret_response({:error, exception}), do: {:error, exception}

  defp get_config!(key), do: Application.fetch_env!(:chat_agent, key)
end
