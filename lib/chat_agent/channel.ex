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

  ## Adding a new channel

  Implement `ChatAgent.Channel.Adapter` and add the module under a new channel
  key in the `adapters` list. See the behaviour for a step-by-step guide and a
  skeleton implementation.
  """

  alias ChatAgent.Channel.Adapter

  @type channel :: atom()

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
      nil -> {:error, {:unknown_channel, channel}}
      module -> module.handle_message(payload)
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

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================

  defp adapter(channel) do
    :chat_agent
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:adapters, [])
    |> Keyword.get(channel)
  end
end
