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
  alias ChatAgent.Tunnel

  # Messages are kept in assigns rather than persisted anywhere, so this is a
  # live monitor, not a history: it shows what arrives while it is open.
  @max_messages 50

  @impl true
  def mount(_params, _session, socket) do
    channels = Channel.list()

    subscribed =
      if connected?(socket) do
        Enum.each(channels, fn {channel, _module} -> Channel.subscribe(channel) end)
        Tunnel.subscribe()
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
     |> assign_tunnel()
     |> assign(:messages, Map.new(channels, fn {channel, _module} -> {channel, []} end))
     |> assign(
       :forms,
       Map.new(channels, fn {channel, _module} -> {channel, new_send_form(channel)} end)
     )}
  end

  @impl true
  def handle_info({:message, %Message{channel: channel} = message}, socket) do
    {:noreply,
     update(socket, :messages, fn messages ->
       Map.update(messages, channel, [message], &Enum.take([message | &1], @max_messages))
     end)}
  end

  # A browser leaves a disabled input out of what it submits, and the composer
  # is disabled until a channel has a conversation to reply to, so the body is
  # not a key these can count on being there.
  def handle_info({:tunnel, %Tunnel.Status{} = status}, socket) do
    {:noreply, assign_tunnel(socket, status)}
  end

  @impl true
  def handle_event("compose", %{"send" => %{"channel" => name} = send}, socket) do
    # The composer's text is kept here rather than only in the browser, so that
    # clearing it after a send is a change the server can actually push.
    case channel_named(socket, name) do
      nil -> {:noreply, socket}
      channel -> {:noreply, put_form(socket, channel, body(send))}
    end
  end

  def handle_event("send_message", %{"send" => %{"channel" => name} = send}, socket) do
    # The channel comes from the form, the recipient from the conversation the
    # newest message arrived on: a bot cannot open a conversation on either
    # service, it can only answer one.
    {:noreply, send_reply(socket, channel_named(socket, name), String.trim(body(send)))}
  end

  # The URLs the chat services have to call, and, when one is being run for
  # them, the tunnel that provides them. Collapsed, because the messages are
  # what this page is for: one line is enough to see the tunnel is up and to
  # copy the URL, and everything else is a click away.
  #
  # A deployment behind DNS runs no tunnel, so there is nothing to report about
  # one there: the callbacks are the whole strip.
  attr :tunnel, ChatAgent.Tunnel.Status, required: true
  attr :public_url, :any, required: true
  attr :channels, :list, required: true

  defp tunnel_panel(assigns) do
    ~H"""
    <details class="tunnel" id="tunnel-panel">
      <summary class="tunnel-summary">
        <span class="tunnel-chevron" aria-hidden="true"></span>

        <span :if={@tunnel.state != :disabled} class={["tunnel-state", "is-#{@tunnel.state}"]}>
          <span class="conn-dot"></span>
          {tunnel_state_label(@tunnel.state)}
        </span>

        <span :if={@tunnel.state == :disabled} class="tunnel-label">Callbacks</span>

        <%= case @public_url do %>
          <% {:ok, url} -> %>
            <a
              href={url}
              target="_blank"
              rel="noopener"
              class="tunnel-summary-url"
              id="tunnel-url"
              phx-hook="KeepSummaryClosed"
            >
              {url}
            </a>
            <.copy_button value={url} label="Copy the public URL" />
          <% {:error, reason} -> %>
            <span class="tunnel-summary-pending">{no_url_reason(reason)}</span>
        <% end %>
      </summary>

      <div class="tunnel-body">
        <p :if={@tunnel.state != :disabled} class="tunnel-provider">
          {provider_name(@tunnel.provider)}
          <span :if={@tunnel.since}>· since {Calendar.strftime(@tunnel.since, "%H:%M")}</span>
        </p>

        <p :if={@tunnel.error} class="tunnel-error">
          Last error: <code>{inspect(@tunnel.error)}</code>
        </p>

        <p class="tunnel-callbacks-hint">
          What each service should be told to call.
        </p>

        <ul class="callback-list">
          <li :for={{channel, _module} <- @channels} class="callback">
            <span class={["callback-channel", "is-#{channel}"]}>{channel}</span>

            <%= case @public_url do %>
              <% {:ok, url} -> %>
                <code class="callback-url">{Channel.webhook_url(channel, url)}</code>
                <.copy_button
                  value={Channel.webhook_url(channel, url)}
                  label={"Copy the #{channel} callback URL"}
                />
              <% {:error, reason} -> %>
                <code class="callback-url is-partial">/{channel}/webhook</code>
                <span class="callback-note">{no_url_reason(reason)}</span>
            <% end %>

            <span
              :if={@tunnel.state != :disabled}
              class={["callback-state", registration_class(@tunnel.webhooks[channel])]}
            >
              {registration_label(@tunnel.webhooks[channel])}
            </span>
          </li>
        </ul>
      </div>
    </details>
    """
  end

  attr :value, :string, required: true
  attr :label, :string, required: true

  defp copy_button(assigns) do
    ~H"""
    <button
      type="button"
      class="copy-button"
      phx-hook="CopyToClipboard"
      id={"copy-#{:erlang.phash2(@value)}"}
      data-copy={@value}
      aria-label={@label}
      title={@label}
    >
      <span class="copy-button-text">Copy</span>
    </button>
    """
  end

  # A lookup rather than a clause per state, so a state nobody wrote a label
  # for reads as unknown instead of crashing the page that reports it.
  @state_labels %{
    connected: "Connected",
    registering: "Registering",
    connecting: "Starting agent",
    authenticating: "Authenticating",
    down: "Not running"
  }

  defp tunnel_state_label(state), do: Map.get(@state_labels, state, "Unknown")

  defp provider_name(nil), do: "No agent"
  defp provider_name(provider), do: provider.name()

  # A channel is only reported on once the tunnel has had a URL to tell it
  # about, so nothing said yet is its own answer rather than a failure.
  defp registration_label(nil), do: "Not registered yet"
  defp registration_label({:ok, :registered}), do: "Registered"
  defp registration_label({:ok, :unchanged}), do: "Already pointed here"
  defp registration_label({:error, :not_supported}), do: "Set outside this app"
  defp registration_label({:error, _reason}), do: "Registration failed"

  defp registration_class({:ok, _outcome}), do: "is-ok"
  defp registration_class({:error, :not_supported}), do: "is-muted"
  defp registration_class({:error, _reason}), do: "is-error"
  defp registration_class(nil), do: "is-muted"

  defp no_url_reason(:not_connected), do: "waiting for the tunnel"
  defp no_url_reason(:not_configured), do: "no public URL configured"

  defp assign_tunnel(socket, status \\ Tunnel.status()) do
    socket
    |> assign(:tunnel, status)
    |> assign(:public_url, public_url(status))
  end

  # The broadcast status carries the URL the tunnel has open, and is the
  # freshest thing this view has: asking the facade again would answer from the
  # server's own state, which is a round trip to learn what just arrived. Only
  # a status with no URL falls back to the configured one, which is how a
  # deployment behind DNS answers.
  defp public_url(%Tunnel.Status{url: nil}), do: Tunnel.url()
  defp public_url(%Tunnel.Status{url: url}), do: {:ok, url}

  defp body(send), do: Map.get(send, "body", "")

  defp send_reply(socket, nil, _body), do: put_flash(socket, :error, "Unknown channel")

  defp send_reply(socket, channel, "") do
    put_flash(socket, :error, "Nothing to send on #{channel}")
  end

  defp send_reply(socket, channel, body) do
    case recipient(socket, channel) do
      nil ->
        put_flash(socket, :error, "No conversation on #{channel} to reply to yet")

      recipient ->
        deliver(socket, channel, recipient, body)
    end
  end

  defp deliver(socket, channel, recipient, body) do
    case Channel.send_message(channel, recipient, body) do
      :ok ->
        socket
        |> put_flash(:info, "Sent on #{channel} to #{recipient}")
        |> put_form(channel, "")

      {:error, reason} ->
        put_flash(socket, :error, "Could not send on #{channel}: #{inspect(reason)}")
    end
  end

  defp channel_named(socket, name) do
    Enum.find_value(socket.assigns.channels, fn {channel, _module} ->
      to_string(channel) == name && channel
    end)
  end

  defp recipient(socket, channel) do
    case newest_inbound(socket.assigns.messages[channel]) do
      %Message{conversation: conversation} -> conversation
      nil -> nil
    end
  end

  # A reply is addressed to whoever last wrote in, so replies this app already
  # sent are skipped: answering our own message would say nothing about who is
  # waiting for an answer.
  defp newest_inbound(messages) do
    Enum.find(messages || [], &(&1.direction == :inbound))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} max_width="page-wide">
      <div class="channels">
        <.tunnel_panel
          tunnel={@tunnel}
          public_url={@public_url}
          channels={@channels}
        />

        <div class="channel-grid">
          <section :for={{channel, module} <- @channels} class="channel-card">
            <div class="channel-card-head">
              <div class="channel-id">
                <span class={["channel-avatar", "is-#{channel}"]}>
                  <.channel_icon channel={channel} />
                </span>
                <div class="channel-names">
                  <div class="channel-title">
                    <h2>{channel}</h2>
                    <.channel_reference
                      channel={channel}
                      module={module}
                      reference={@references[channel]}
                    />
                  </div>
                  <div class="channel-fields">
                    <code :for={{name, _meaning} <- @references[channel].fields}>{name}</code>
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
                <li
                  :for={message <- @messages[channel]}
                  class={["message", "is-#{message.direction}"]}
                >
                  <div class="message-bubble">
                    <p class="message-ids">
                      <span :for={{names, value} <- merge_repeats(message.identifiers)}>
                        <span class="message-id-name">{Enum.join(names, " · ")}</span>
                        <span class="message-id-value" title={value}>{value}</span>
                      </span>
                      <span :if={message.direction == :outbound} class="message-manual">
                        sent from this dashboard
                      </span>
                    </p>
                    <p class="message-text">{message.text}</p>
                    <time datetime={DateTime.to_iso8601(message.received_at)}>
                      {Calendar.strftime(message.received_at, "%H:%M")}
                    </time>
                  </div>
                </li>
              </ol>

              <.form
                for={@forms[channel]}
                phx-change="compose"
                phx-submit="send_message"
                id={"send-form-#{channel}"}
                class="message-form"
              >
                <.input
                  field={@forms[channel][:channel]}
                  type="hidden"
                  id={"send-#{channel}-channel"}
                />

                <p class="message-form-to">
                  <%= if replying_to = newest_inbound(@messages[channel]) do %>
                    <span class="message-form-to-label">Replying to</span>
                    <span class="message-id-name">{conversation_field(replying_to)}</span>
                    <span class="message-id-value">{replying_to.conversation}</span>
                  <% else %>
                    <span class="message-form-to-label">
                      Nothing to reply to yet. A reply is addressed to the conversation a
                      message arrived on.
                    </span>
                  <% end %>
                </p>

                <div class="message-form-row">
                  <.input
                    field={@forms[channel][:body]}
                    type="text"
                    placeholder={"Reply on #{channel}"}
                    aria-label={"Reply on #{channel}"}
                    autocomplete="off"
                    id={"send-#{channel}-body"}
                    disabled={newest_inbound(@messages[channel]) == nil}
                  />
                  <button
                    type="submit"
                    class="message-send"
                    disabled={newest_inbound(@messages[channel]) == nil}
                    phx-disable-with="Sending"
                  >
                    Send
                  </button>
                </div>
              </.form>
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Several identifiers can legitimately carry the same value: a Telegram
  # private chat reports the user's own id as both chat.id and from.id. Naming
  # them together beats printing the number twice, and still says that both
  # fields arrived, which dropping one of them would not.
  defp merge_repeats(identifiers) do
    Enum.reduce(identifiers, [], &merge_identifier/2)
  end

  defp merge_identifier({name, value}, merged) do
    case Enum.find_index(merged, fn {_names, seen} -> seen == value end) do
      nil -> merged ++ [{[name], value}]
      index -> List.update_at(merged, index, fn {names, seen} -> {names ++ [name], seen} end)
    end
  end

  # Name the field a reply is addressed to, using the channel's own vocabulary,
  # so the composer and the messages above it agree on what the number is.
  defp conversation_field(%Message{conversation: conversation, identifiers: identifiers}) do
    case Enum.find(merge_repeats(identifiers), fn {_names, value} -> value == conversation end) do
      {names, ^conversation} -> Enum.join(names, " · ")
      nil -> "conversation"
    end
  end

  defp put_form(socket, channel, body) do
    update(socket, :forms, &Map.put(&1, channel, new_send_form(channel, body)))
  end

  defp new_send_form(channel, body \\ "") do
    to_form(%{"channel" => to_string(channel), "body" => body}, as: "send")
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
