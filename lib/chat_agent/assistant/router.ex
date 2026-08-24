defmodule ChatAgent.Assistant.Router do
  @moduledoc """
  Follows every channel, and decides which conversations get answered.

  A conversation starts closed. `/auth <password>` opens a session on the
  default assistant, and `/auth-<name> <password>` names one instead. From then
  on the conversation belongs to a `ChatAgent.Assistant.Session` process, which
  holds it and answers it; this router only decides who gets one.

  `/auth <password> --url` and `/auth <password> --renew` are the same password
  spent on one answer about the public URL instead of on a session. They open
  nothing, they close nothing, and they are answered here rather than in a
  session, so they read the same whether a conversation has one open or not.

  That split is what keeps the router quick: asking an assistant takes as long
  as the assistant takes, and it happens in the session's process, so a
  conversation waiting on a slow answer never delays another conversation's
  first word.

  A wrong password is answered with nothing at all. Saying "wrong password"
  would confirm that a password is what is wanted, and this listens to whoever
  can reach the bot. That is true of every form of it, so asking for the URL
  with the wrong password is met with the same silence as asking for a session
  with it.
  """

  use GenServer

  alias ChatAgent.Assistant
  alias ChatAgent.Assistant.Session
  alias ChatAgent.Channel
  alias ChatAgent.Channel.Message
  alias ChatAgent.Tunnel

  require Logger

  ### ==========================================================================
  ### Public functions
  ### ==========================================================================

  @doc """
  Start the router.

  Options: `:name` to register under, and `:session_supervisor` to start
  sessions from. Everything about who may talk, and for how long, is read from
  `ChatAgent.Assistant`'s configuration at the moment it matters.
  """
  @spec start_link(options :: keyword()) :: GenServer.on_start()
  def start_link(options) do
    {name, options} = Keyword.pop(options, :name, __MODULE__)

    GenServer.start_link(__MODULE__, options, name: name)
  end

  @doc """
  The conversations with an open session, and the process holding each.
  """
  @spec sessions(server :: GenServer.server()) :: %{optional(Session.key()) => map()}
  def sessions(server \\ __MODULE__), do: GenServer.call(server, :sessions)

  ### ==========================================================================
  ### Callback functions
  ### ==========================================================================

  @impl true
  def init(options) do
    Enum.each(Channel.list(), fn {channel, _module} -> Channel.subscribe(channel) end)

    if is_nil(Assistant.salted_password()) do
      Logger.warning(%{
        what: "assistant_router_locked",
        reason: "no password configured, so no conversation can be answered"
      })
    end

    {:ok,
     %{
       sessions: %{},
       keys: %{},
       supervisor:
         Keyword.get(options, :session_supervisor, ChatAgent.Assistant.SessionSupervisor)
     }}
  end

  @impl true
  def handle_call(:sessions, _from, state), do: {:reply, state.sessions, state}

  @impl true
  def handle_info({:message, %Message{direction: :inbound} = message}, state) do
    key = {message.channel, message.conversation}
    attempt = Assistant.authentication(message.text)

    case attempt do
      # A question about the public URL, which is nothing to do with a session:
      # it is answered before one is looked for, so a conversation with a
      # session open gets the URL rather than an assistant's opinion of it, and
      # the session it was asked from is left exactly as it was.
      {:ok, %{action: action} = asked} when action != :open ->
        {:noreply, tunnel(state, asked, message)}

      _session_or_nothing ->
        case Map.fetch(state.sessions, key) do
          {:ok, %{pid: session}} ->
            Session.say(session, message)

            {:noreply, state}

          :error ->
            {:noreply, authenticate(state, key, attempt, message)}
        end
    end
  end

  # A reply this app sent, arriving back through the broadcast it made.
  def handle_info({:message, %Message{}}, state), do: {:noreply, state}

  # A session ended, by asking, by sitting idle, or by failing. Either way the
  # conversation it held is closed, and its next message starts over.
  def handle_info({:DOWN, _reference, :process, pid, _reason}, state) do
    case Map.pop(state.keys, pid) do
      {nil, _keys} ->
        {:noreply, state}

      {key, keys} ->
        Assistant.broadcast({:session_closed, key})

        {:noreply, %{state | keys: keys, sessions: Map.delete(state.sessions, key)}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================

  # Answered only to whoever knows the password, and the state is handed
  # straight back: neither of these opens, closes, or touches a session.
  defp tunnel(state, asked, %Message{} = message) do
    if correct?(asked.password), do: reply(message, tunnel_answer(asked.action))

    state
  end

  defp tunnel_answer(:url), do: public_url()
  defp tunnel_answer(:renew), do: renewed_url()

  # The URL on its own, so that whoever asked can paste it where it is wanted.
  # The two failures are told apart, since one is worth waiting out and the
  # other is worth configuring.
  defp public_url do
    case Tunnel.url() do
      {:ok, url} -> url
      {:error, :not_connected} -> "No public URL yet: the tunnel is still connecting."
      {:error, :not_configured} -> "No public URL is configured here."
    end
  end

  # Said as soon as the tunnel has been told to start over rather than when it
  # has, since opening one takes as long as the service takes and waiting here
  # would be the router waiting: the URL is asked for again once it exists.
  defp renewed_url do
    case Tunnel.renew() do
      :ok ->
        "Renewing the public URL. Ask for it with --url in a moment."

      {:error, :not_configured} ->
        "The public URL here is not a tunnel, so there is nothing to renew."

      {:error, :down} ->
        "No tunnel is running here."
    end
  end

  # Nothing that could open a session, said by a conversation that has none.
  defp authenticate(state, _key, :error, _message), do: state

  defp authenticate(state, key, {:ok, asked}, %Message{} = message) do
    with true <- correct?(asked.password),
         {:ok, assistant} <- resolve(asked.assistant),
         {:ok, working_dir} <- working_dir(asked.work_dir) do
      open(state, key, assistant, working_dir, message)
    else
      # Named an assistant that is not configured. Worth saying, since whoever
      # said it already knows the password.
      {:error, {:unknown_assistant, named}} ->
        reply(message, "No assistant called #{named} here.")
        state

      # Named somewhere to work that is not on offer. Said plainly, and without
      # naming what is, since a list of directories is a map of the machine.
      {:error, {:unknown_work_dir, named}} ->
        reply(message, "No working directory called #{named} here.")
        state

      # Nothing to choose from. Said plainly to whoever asked, and named in the
      # log for whoever configured it, since the usual reason is that the root
      # was set somewhere that nothing reads.
      {:error, :work_dir_not_offered} ->
        Logger.warning(%{
          what: "assistant_work_dir_not_offered",
          reason: "no :working_dir_root configured under ChatAgent.Assistant"
        })

        reply(message, "No working directories are offered here, so --work-dir cannot be used.")
        state

      # No attempt, or the wrong password. Both are met with silence.
      _ ->
        state
    end
  end

  defp open(state, key, assistant, working_dir, %Message{} = message) do
    id = Session.generate_id()

    case DynamicSupervisor.start_child(
           state.supervisor,
           {Session, key: key, assistant: assistant, id: id, working_dir: working_dir}
         ) do
      {:ok, pid} ->
        Process.monitor(pid)

        session = %{pid: pid, assistant: assistant, id: id, key: key, working_dir: working_dir}

        Logger.info(%{
          what: "assistant_session_opened",
          channel: elem(key, 0),
          assistant: assistant,
          session: id
        })

        # Said out loud, so anything watching the conversations can show which
        # of them is being answered and by what.
        Assistant.broadcast({:session_opened, session})

        reply(
          message,
          "Authenticated. Talking to #{assistant}#{in_directory(working_dir)}. Session #{id}."
        )

        %{
          state
          | sessions: Map.put(state.sessions, key, session),
            keys: Map.put(state.keys, pid, key)
        }

      {:error, reason} ->
        Logger.error(%{what: "assistant_session_not_started", reason: inspect(reason)})

        reply(message, "Sorry, I could not start a session.")

        state
    end
  end

  # A conversation that named nowhere gets the configured default, which is
  # written as a name under the same root that --work-dir picks from.
  defp working_dir(nil), do: {:ok, Assistant.default_working_dir()}

  defp working_dir(named) do
    case Assistant.working_dir(named) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, :not_offered} -> {:error, :work_dir_not_offered}
      {:error, :not_found} -> {:error, {:unknown_work_dir, named}}
    end
  end

  defp in_directory(nil), do: ""
  defp in_directory(working_dir), do: " in #{Path.basename(working_dir)}"

  defp resolve(nil) do
    default = Assistant.default()

    if Keyword.has_key?(Assistant.list(), default) do
      {:ok, default}
    else
      {:error, {:unknown_assistant, default}}
    end
  end

  defp resolve(named) do
    Assistant.list()
    |> Enum.find(fn {assistant, _module} -> to_string(assistant) == named end)
    |> case do
      {assistant, _module} -> {:ok, assistant}
      nil -> {:error, {:unknown_assistant, named}}
    end
  end

  # Checked against a hash, so what is configured is not what is typed, and
  # nothing that reads the configuration learns the password.
  #
  # With none configured the work is done anyway and thrown away: answering a
  # guess faster when there is no password to check would say so.
  defp correct?(given) do
    case Assistant.salted_password() do
      nil ->
        Pbkdf2.no_user_verify()
        false

      salted_password ->
        Pbkdf2.verify_pass(given, salted_password)
    end
  end

  # A reply the channel refused is a reply nobody sees: it reaches neither the
  # person nor the dashboard, since only a message that was sent is broadcast.
  # Silence there looks exactly like a bug in here.
  defp reply(%Message{} = message, text) do
    case Channel.send_message(message.channel, message.conversation, text) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(%{
          what: "assistant_reply_not_sent",
          channel: message.channel,
          reason: inspect(reason)
        })

        :ok
    end
  end
end
