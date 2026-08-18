defmodule ChatAgentWeb.ChannelLive do
  @moduledoc """
  Live view of every configured channel and the messages arriving on it.

  The channel list comes from configuration, so a newly registered channel
  shows up here without touching this module. Each connected view subscribes
  to every channel's topic and appends what arrives.
  """

  use ChatAgentWeb, :live_view

  alias ChatAgent.Channel
  alias ChatAgent.Channel.Message

  # Messages are kept in assigns rather than persisted anywhere, so this is a
  # live monitor, not a history: it shows what arrives while it is open.
  @max_messages 50

  @impl true
  def mount(_params, _session, socket) do
    channels = Channel.list()

    if connected?(socket) do
      Enum.each(channels, fn {channel, _module} -> Channel.subscribe(channel) end)
    end

    {:ok,
     socket
     |> assign(:page_title, "Channels")
     |> assign(:connected?, connected?(socket))
     |> assign(:channels, channels)
     |> assign(:messages, Map.new(channels, fn {channel, _module} -> {channel, []} end))}
  end

  @impl true
  def handle_info({:message, %Message{channel: channel} = message}, socket) do
    {:noreply,
     update(socket, :messages, fn messages ->
       Map.update(messages, channel, [message], &Enum.take([message | &1], @max_messages))
     end)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} max_width="page-wide">
      <div class="channels">
        <header class="channels-header">
          <div>
            <h1>Channels</h1>
            <p class="channels-subtitle">
              Every module implementing <code>ChatAgent.Channel.Adapter</code>, and the
              messages arriving on it.
            </p>
          </div>
          <span class={["conn-badge", @connected? && "is-live"]}>
            <span class="conn-dot"></span>
            {if @connected?, do: "Subscribed", else: "Connecting"}
          </span>
        </header>

        <div class="channel-grid">
          <section :for={{channel, module} <- @channels} class="channel-card">
            <div class="channel-card-head">
              <div class="channel-id">
                <span class="channel-avatar">{channel_initial(channel)}</span>
                <div>
                  <h2>{channel}</h2>
                  <code>{inspect(module)}</code>
                </div>
              </div>
              <span class="channel-count">{length(@messages[channel])}</span>
            </div>

            <ol :if={@messages[channel] != []} class="message-list">
              <li :for={message <- @messages[channel]} class="message">
                <div class="message-head">
                  <span class="message-sender">{message.sender}</span>
                  <time datetime={DateTime.to_iso8601(message.received_at)}>
                    {Calendar.strftime(message.received_at, "%H:%M:%S")}
                  </time>
                </div>
                <p class="message-text">{message.text}</p>
              </li>
            </ol>

            <p :if={@messages[channel] == []} class="channel-empty">
              Waiting for messages on <code>{Channel.topic(channel)}</code>
            </p>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp channel_initial(channel) do
    channel |> Atom.to_string() |> String.first() |> String.upcase()
  end
end
