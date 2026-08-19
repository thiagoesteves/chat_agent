defmodule ChatAgent.Channel do
  @moduledoc """
  Routes messages to and from the module configured for each chat channel.

  Every channel module implements `ChatAgent.Channel.Adapter`, so a caller only
  needs to name the channel it is talking on. The mapping from channel to
  module lives in configuration, which keeps callers free of module names and
  lets a test swap a channel for a stub without touching the code under test.

  ## Available channels

  | Channel     | Module                       | Inbound payload                        | Recipient    |
  |-------------|------------------------------|----------------------------------------|--------------|
  | `:whatsapp` | `ChatAgent.Channel.Whatsapp` | One entry of a webhook `messages` list | Phone number |
  | `:telegram` | `ChatAgent.Channel.Telegram` | One Telegram update object             | Chat id      |

  ## Configuration

      config :chat_agent, ChatAgent.Channel,
        adapters: [
          whatsapp: ChatAgent.Channel.Whatsapp,
          telegram: ChatAgent.Channel.Telegram
        ]

  ## Subscribing to inbound messages

  Every chat message a channel receives is broadcast to that channel's topic,
  so a LiveView (or anything else) can follow along:

      ChatAgent.Channel.subscribe(:whatsapp)
      # => receives {:message, %ChatAgent.Channel.Message{}}

  ## Adding a new channel

  Implement `ChatAgent.Channel.Adapter` and add the module under a new channel
  key in the `adapters` list. See the behaviour for a step-by-step guide and a
  skeleton implementation.
  """

  alias ChatAgent.Channel.Adapter
  alias ChatAgent.Channel.Message

  @type channel :: atom()

  @pubsub ChatAgent.PubSub

  ### ==========================================================================
  ### Public functions
  ### ==========================================================================

  @doc """
  Dispatch an inbound payload to the module registered for `channel`.

  Returns whatever the channel module returns, or `{:error, {:unknown_channel,
  channel}}` when none is configured for it.

  ## Examples

      iex> ChatAgent.Channel.handle_message(:telegram, %{"update_id" => 1})
      :ok

      iex> ChatAgent.Channel.handle_message(:carrier_pigeon, %{})
      {:error, {:unknown_channel, :carrier_pigeon}}
  """
  @spec handle_message(channel :: channel(), payload :: map()) :: :ok | {:error, term()}
  def handle_message(channel, payload) do
    case adapter(channel) do
      nil ->
        {:error, {:unknown_channel, channel}}

      module ->
        case module.handle_message(payload) do
          {:ok, %Message{} = message} -> broadcast(channel, message)
          other -> other
        end
    end
  end

  @doc """
  Send a plain text message out on `channel`.

  Returns whatever the channel module returns, or `{:error, {:unknown_channel,
  channel}}` when none is configured for it.

  Options say who is sending, for the broadcast that follows: `:sender`, which
  defaults to `"you"` for a person at the dashboard, and `:identifiers` to name
  what the sender wants a reader to see, such as the session that answered.

  ## Examples

      iex> ChatAgent.Channel.send_message(:telegram, 123_456, "Hello")
      :ok

      iex> ChatAgent.Channel.send_message(:carrier_pigeon, "anyone", "Hello")
      {:error, {:unknown_channel, :carrier_pigeon}}
  """
  @spec send_message(
          channel :: channel(),
          recipient :: Adapter.recipient(),
          body :: String.t(),
          options :: keyword()
        ) :: :ok | {:error, term()}
  def send_message(channel, recipient, body, options \\ []) do
    case adapter(channel) do
      nil ->
        {:error, {:unknown_channel, channel}}

      module ->
        with :ok <- module.send_message(recipient, body) do
          # Subscribers see a reply the same way they see an inbound message, so
          # a conversation reads as a whole and every open view stays in step.
          broadcast(channel, sent_message(recipient, body, options))
        end
    end
  end

  @doc """
  Point `channel`'s service at the webhook it should call on `base_url`.

  `base_url` is the public URL of this app, without a path: this builds the
  channel's own webhook URL from it and hands that to the channel module.

  Returns `{:ok, :registered}` when the service was updated, `{:ok, :unchanged}`
  when it already pointed there, and an error otherwise.

  ## Examples

      iex> ChatAgent.Channel.register_webhook(:telegram, "https://example.com")
      {:ok, :registered}
  """
  @spec register_webhook(channel :: channel(), base_url :: String.t()) ::
          {:ok, :registered | :unchanged} | {:error, term()}
  def register_webhook(channel, base_url) do
    case adapter(channel) do
      nil -> {:error, {:unknown_channel, channel}}
      module -> module.register_webhook(webhook_url(channel, base_url))
    end
  end

  @doc """
  The URL `channel`'s webhook is served on, under `base_url`.

  Webhook routes all follow the one shape declared in `ChatAgentWeb.Router`,
  which is what lets this be built rather than configured per channel.

  ## Examples

      iex> ChatAgent.Channel.webhook_url(:telegram, "https://example.com/")
      "https://example.com/telegram/webhook"
  """
  @spec webhook_url(channel :: channel(), base_url :: String.t()) :: String.t()
  def webhook_url(channel, base_url) do
    "#{String.trim_trailing(base_url, "/")}/#{channel}/webhook"
  end

  @doc """
  List every configured channel and the module that speaks it.

  ## Examples

      iex> ChatAgent.Channel.list()
      [whatsapp: ChatAgent.Channel.Whatsapp, telegram: ChatAgent.Channel.Telegram]
  """
  @spec list() :: [{channel(), module()}]
  def list do
    :chat_agent
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:adapters, [])
  end

  @doc """
  Subscribe the calling process to every chat message received on `channel`.

  Subscribers receive `{:message, %ChatAgent.Channel.Message{}}`.
  """
  @spec subscribe(channel :: channel()) :: :ok | {:error, {:already_registered, pid()}}
  def subscribe(channel), do: Phoenix.PubSub.subscribe(@pubsub, topic(channel))

  @doc """
  Stop receiving messages for `channel`.
  """
  @spec unsubscribe(channel :: channel()) :: :ok
  def unsubscribe(channel), do: Phoenix.PubSub.unsubscribe(@pubsub, topic(channel))

  @doc """
  The PubSub topic carrying `channel`'s inbound messages.
  """
  @spec topic(channel :: channel()) :: String.t()
  def topic(channel), do: "channel:#{channel}"

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================

  defp broadcast(channel, message) do
    Phoenix.PubSub.broadcast(@pubsub, topic(channel), {:message, %{message | channel: channel}})
  end

  # A service does not hand back a message when it accepts one, so the reply is
  # described from what was asked of it. The conversation is where the reply
  # went, and `sender` is whoever in this app sent it: a person at the
  # dashboard by default, or the assistant that answered when one did. That is
  # the difference between "sent from this dashboard" and "sent by claude", and
  # a reader can only tell them apart if the sender travels with the message.
  defp sent_message(recipient, body, options) do
    recipient = to_string(recipient)

    Message.new(
      sender: Keyword.get(options, :sender, "you"),
      conversation: recipient,
      text: body,
      direction: :outbound,
      identifiers: Keyword.get(options, :identifiers, []) ++ [{"to", recipient}]
    )
  end

  defp adapter(channel), do: Keyword.get(list(), channel)
end
