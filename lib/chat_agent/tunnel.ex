defmodule ChatAgent.Tunnel do
  @moduledoc """
  The public URL this node is reachable on, and the tunnel that provides it.

  A chat service delivers its messages by calling a URL, which means this app
  has to be reachable from the internet before any channel works. In production
  that is a DNS name pointing at the deployment. On a development machine it is
  not, so a tunnel agent (ngrok or Pinggy, see
  `ChatAgent.Tunnel.Provider.Adapter`) opens a public URL and forwards it to the
  local endpoint.

  Both cases answer the same question, `url/0`, so nothing else in the app
  needs to know which one it is running behind:

      ChatAgent.Tunnel.url()
      #=> {:ok, "https://a1b2c3.ngrok-free.app"}

      ChatAgent.Tunnel.webhook_url(:telegram)
      #=> {:ok, "https://a1b2c3.ngrok-free.app/telegram/webhook"}

  ## Configuration

      config :chat_agent, ChatAgent.Tunnel,
        # The agent to run. `nil` means no tunnel: `url/0` then answers the
        # static `:url` below, which is how a deployment behind DNS runs.
        provider: ChatAgent.Tunnel.Provider.Ngrok,
        # Static public URL. Set from PUBLIC_URL, or from the endpoint's own
        # host in production. A URL that is already public leaves nothing for
        # a tunnel to do, so setting this runs no agent even when one is
        # configured.
        url: nil,
        # The local port to forward to. With none set, the port the endpoint
        # actually bound, which is the only right answer when it was asked to
        # bind port 0.
        port: nil,
        # How long to wait for the agent to report its URL before restarting it.
        connect_timeout: :timer.seconds(30),
        # Ceiling for the retry backoff between attempts.
        max_backoff: :timer.minutes(1),
        # How often each channel is asked whether its service is managing to
        # deliver to the URL it was given.
        health_interval: :timer.minutes(1)

  ## Following the tunnel

  Every state change is broadcast, along with every delivery check that says
  something new, so a page can show the current URL and whether anything is
  arriving on it without polling for either:

      ChatAgent.Tunnel.subscribe()
      # => receives {:tunnel, %ChatAgent.Tunnel.Status{}}
  """

  alias ChatAgent.Channel
  alias ChatAgent.Tunnel.Server
  alias ChatAgent.Tunnel.Status

  @pubsub ChatAgent.PubSub
  @topic "tunnel"

  ### ==========================================================================
  ### Public functions
  ### ==========================================================================

  @doc """
  The public base URL of this node, without a trailing slash.

  Answers the statically configured URL when there is one, the running
  tunnel's URL otherwise, and an error while no URL is known yet.
  """
  @spec url() :: {:ok, String.t()} | {:error, :not_connected | :not_configured}
  def url do
    config = config()

    cond do
      url = config[:url] -> {:ok, String.trim_trailing(url, "/")}
      config[:provider] -> Server.url()
      true -> {:error, :not_configured}
    end
  end

  @doc """
  The URL a channel's webhook is reachable on, for handing to that service.
  """
  @spec webhook_url(channel :: Channel.channel()) ::
          {:ok, String.t()} | {:error, :not_connected | :not_configured}
  def webhook_url(channel) do
    with {:ok, url} <- url() do
      {:ok, Channel.webhook_url(channel, url)}
    end
  end

  @doc """
  The current state of the tunnel.

  Reports `:disabled` when no provider is configured and `:down` when one is
  but its server is not running.
  """
  @spec status() :: Status.t()
  def status do
    if enabled?() do
      Server.status()
    else
      %Status{state: :disabled, url: config()[:url]}
    end
  end

  @doc """
  Open a new public URL, by running the tunnel agent again.

  Answers `{:error, :not_configured}` where the URL is a static one, since
  there is no agent to run and a deployment behind DNS is reachable at the same
  place tomorrow. Answers `{:error, :down}` where an agent is configured but
  its server is not running.

  Returns as soon as the tunnel has been told to start over. The new URL
  arrives on the topic (see `subscribe/0`) once the service has given one, and
  `url/0` answers it from then on.
  """
  @spec renew() :: :ok | {:error, :not_configured | :down}
  def renew do
    if enabled?(), do: Server.renew(), else: {:error, :not_configured}
  end

  @doc """
  Ask every channel how delivery to its webhook is going, and repair what is
  broken.

  A registration that was accepted can stop working without anything here
  failing, so this is the question registration cannot answer: the service is
  asked what it believes it is calling and how that has been going. What comes
  back is carried on `ChatAgent.Tunnel.Status`, and a channel that reports
  trouble is told again where to call, up to and including being given a new
  URL (see `ChatAgent.Tunnel.Server`).

  Runs on an interval on its own; this is that check asked for now. Answers
  `{:error, :not_connected}` while there is no URL to check, and `{:error,
  :not_configured}` where the URL is a static one, since a deployment behind
  DNS is reachable at the same place tomorrow.
  """
  @spec check_health() :: :ok | {:error, :not_configured | :not_connected | :down}
  def check_health do
    if enabled?(), do: Server.check_health(), else: {:error, :not_configured}
  end

  @doc """
  Whether a tunnel agent is run at all.

  A statically configured URL is already public, so an agent would have
  nothing to open: the two are alternatives rather than layers. The
  application's supervision tree starts the state machine on this, and nothing
  else decides it.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    config = config()

    not is_nil(config[:provider]) and is_nil(config[:url])
  end

  @doc """
  Whether a public URL is available right now.
  """
  @spec connected?() :: boolean()
  def connected? do
    match?({:ok, _url}, url())
  end

  @doc """
  Subscribe the calling process to every tunnel state change.

  Subscribers receive `{:tunnel, %ChatAgent.Tunnel.Status{}}`.
  """
  @spec subscribe() :: :ok | {:error, {:already_registered, pid()}}
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, topic())

  @doc """
  Stop receiving tunnel state changes.
  """
  @spec unsubscribe() :: :ok
  def unsubscribe, do: Phoenix.PubSub.unsubscribe(@pubsub, topic())

  @doc """
  The PubSub topic carrying tunnel state changes.
  """
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc false
  @spec broadcast(status :: Status.t()) :: :ok
  def broadcast(%Status{} = status) do
    Phoenix.PubSub.broadcast(@pubsub, topic(), {:tunnel, status})
  end

  @doc false
  @spec config() :: keyword()
  def config, do: Application.get_env(:chat_agent, __MODULE__, [])
end
