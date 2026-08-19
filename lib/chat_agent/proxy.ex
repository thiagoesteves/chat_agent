defmodule ChatAgent.Proxy do
  @moduledoc false

  @pubsub ChatAgent.PubSub

  @topic "proxy"

  @type proxy :: atom()

  ### ==========================================================================
  ### Public functions
  ### ==========================================================================

  def connected?(), do: default().connected?()


    def status(), do: default().status()

  @doc """

  """
  @spec subscribe() :: :ok | {:error, {:already_registered, pid()}}
  def subscribe(), do: Phoenix.PubSub.subscribe(@pubsub, topic())

  @doc """

  """
  @spec unsubscribe() :: :ok
  def unsubscribe(), do: Phoenix.PubSub.unsubscribe(@pubsub, topic())

  @doc """

  """
  @spec topic() :: String.t()
  def topic() do
     "proxy:#{default.name()}"
  end

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================
  defp default, do: Application.fetch_env!(:chat_agent, __MODULE__)[:adapter]
end
