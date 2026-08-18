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

    subscribed =
      if connected?(socket) do
        Enum.each(channels, fn {channel, _module} -> Channel.subscribe(channel) end)
        MapSet.new(channels, fn {channel, _module} -> channel end)
      else
        MapSet.new()
      end

    {:ok,
     socket
     |> assign(:page_title, "Channels")
     |> assign(:channels, channels)
     |> assign(
       :references,
       Map.new(channels, fn {channel, module} ->
         {channel, module.reference()}
       end)
     )
     |> assign(:subscribed, subscribed)
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
          <h1>Channels</h1>
          <p class="channels-subtitle">
            Every module implementing <code>ChatAgent.Channel.Adapter</code>, and the messages
            arriving on it.
          </p>
        </header>

        <div class="channel-grid">
          <section :for={{channel, module} <- @channels} class="channel-card">
            <div class="channel-card-head">
              <div class="channel-id">
                <span class={["channel-avatar", "is-#{channel}"]}>
                  <.channel_icon channel={channel} />
                </span>
                <div class="channel-names">
                  <h2>{channel}</h2>
                  <div class="channel-fields">
                    <code :for={{name, _meaning} <- @references[channel].fields}>{name}</code>
                    <.channel_reference
                      channel={channel}
                      module={module}
                      reference={@references[channel]}
                    />
                  </div>
                </div>
              </div>
              <div class="channel-meta">
                <span class={["conn-badge", MapSet.member?(@subscribed, channel) && "is-live"]}>
                  <span class="conn-dot"></span>
                  {if MapSet.member?(@subscribed, channel), do: "Subscribed", else: "Connecting"}
                </span>
                <span class="channel-count" title="Messages received">
                  {length(@messages[channel])}
                </span>
              </div>
            </div>

            <div class={["channel-body", "is-#{channel}"]}>
              <ol :if={@messages[channel] != []} class="message-list">
                <li :for={message <- @messages[channel]} class="message">
                  <div class="message-bubble">
                    <p class="message-ids">
                      <span :for={{name, value} <- message.identifiers}>
                        <span class="message-id-name">{name}</span>
                        <span class="message-id-value" title={value}>{value}</span>
                      </span>
                    </p>
                    <p class="message-text">{message.text}</p>
                    <time datetime={DateTime.to_iso8601(message.received_at)}>
                      {Calendar.strftime(message.received_at, "%H:%M")}
                    </time>
                  </div>
                </li>
              </ol>

              <p :if={@messages[channel] == []} class="channel-empty">
                Waiting for messages on <code>{Channel.topic(channel)}</code>
              </p>
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :channel, :atom, required: true
  attr :module, :atom, required: true
  attr :reference, :map, required: true

  defp channel_reference(assigns) do
    ~H"""
    <details class="channel-ref" id={"reference-#{@channel}"}>
      <summary title={"What #{@channel} reports"}>
        <span aria-hidden="true">?</span>
        <span class="sr-only">What {@channel} reports</span>
      </summary>

      <div class="channel-ref-panel">
        <dl>
          <div :for={{name, meaning} <- @reference.fields}>
            <dt><code>{name}</code></dt>
            <dd>{meaning}</dd>
          </div>
        </dl>

        <footer>
          <code>{inspect(@module)}</code>
          <a href={@reference.url} target="_blank" rel="noopener noreferrer">
            API reference <span aria-hidden="true">&#8599;</span>
          </a>
        </footer>
      </div>
    </details>
    """
  end

  # Brand glyphs drawn as a white mark on the brand colour, so they read the
  # same in either theme. A chat bubble stands in for any channel added later.
  attr :channel, :atom, required: true

  defp channel_icon(%{channel: :whatsapp} = assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path
        fill="currentColor"
        d="M12 2a10 10 0 0 0-8.6 15.1L2 22l5-1.3A10 10 0 1 0 12 2Z"
      />
      <path
        fill="var(--brand)"
        d="M9.4 7.6c-.2-.5-.4-.5-.6-.5h-.6c-.2 0-.5.1-.7.4-.3.3-1 1-1 2.3 0 1.4 1 2.7 1.2 2.9.1.2 2 3.1 4.8 4.3 2.4.9 2.9.7 3.4.7.5 0 1.6-.7 1.9-1.3.2-.7.2-1.2.1-1.3 0-.1-.2-.2-.5-.3l-1.9-1c-.3-.1-.4-.1-.6.1l-.8 1.1c-.2.2-.3.2-.6.1-.3-.1-1.2-.4-2.2-1.4-.8-.7-1.4-1.6-1.5-1.9-.2-.3 0-.4.1-.5l.4-.5.3-.5c0-.2 0-.3-.1-.5l-1-2.3Z"
      />
    </svg>
    """
  end

  defp channel_icon(%{channel: :telegram} = assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path
        fill="currentColor"
        d="M9.8 15.6 9.6 19c.4 0 .6-.2.8-.4l1.9-1.8 3.9 2.9c.7.4 1.2.2 1.4-.7l2.6-12c.2-1-.4-1.4-1-1.2L3.6 10.3c-1 .4-1 .9-.2 1.2l4.1 1.3 9.5-6c.4-.3.9-.1.5.2l-7.7 8.6Z"
      />
    </svg>
    """
  end

  defp channel_icon(assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
      <path
        d="M21 11.5a8.38 8.38 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.38 8.38 0 0 1-3.8-.9L3 21l1.9-5.7a8.38 8.38 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.38 8.38 0 0 1 3.8-.9h.5a8.48 8.48 0 0 1 8 8v.5Z"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
    </svg>
    """
  end
end
