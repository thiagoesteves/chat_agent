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

  ## Examples

      iex> ChatAgent.Channel.send_message(:telegram, 123_456, "Hello")
      :ok

      iex> ChatAgent.Channel.send_message(:carrier_pigeon, "anyone", "Hello")
      {:error, {:unknown_channel, :carrier_pigeon}}
  """
  @spec send_message(channel :: channel(), recipient :: Adapter.recipient(), body :: String.t()) ::
          :ok | {:error, term()}
  def send_message(channel, recipient, body) do
    case adapter(channel) do
      nil -> {:error, {:unknown_channel, channel}}
      module -> module.send_message(recipient, body)
    end
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
  Look up the module registered for `channel`.

  ## Examples

      iex> ChatAgent.Channel.fetch(:telegram)
      {:ok, ChatAgent.Channel.Telegram}

      iex> ChatAgent.Channel.fetch(:carrier_pigeon)
      :error
  """
  @spec fetch(channel :: channel()) :: {:ok, module()} | :error
  def fetch(channel), do: Keyword.fetch(list(), channel)

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

  defp adapter(channel), do: Keyword.get(list(), channel)
end
