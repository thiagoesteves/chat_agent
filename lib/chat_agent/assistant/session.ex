defmodule ChatAgent.Assistant.Session do
  @moduledoc """
  One authenticated conversation, and everything that belongs to it.

  A session is a process rather than an entry in a map, which is what makes the
  rest of it simple: the conversation it is holding is this process's state,
  asking the assistant is a call this process waits for, and a conversation
  that is waiting for a slow answer is one process waiting rather than all of
  them.

  It closes itself in three ways, all the same ending, and says so on the first
  two, since a conversation that goes quiet is indistinguishable from one that
  broke:

    * `/stop`, which is the idle timeout asked for rather than waited for
    * nothing said for `session_timeout`, which the process timeout provides
    * the router going down, which takes its sessions with it

  Whatever it was holding goes with it, so the next message from that
  conversation starts closed again.
  """

  use GenServer, restart: :temporary

  alias ChatAgent.Assistant
  alias ChatAgent.Channel
  alias ChatAgent.Channel.Message

  require Logger

  @type key :: {channel :: atom(), conversation :: String.t()}

  @doc """
  An identifier for a session, short enough to read out in a chat.
  """
  @spec generate_id() :: String.t()
  def generate_id, do: 3 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  ### ==========================================================================
  ### Public functions
  ### ==========================================================================

  @spec start_link(options :: keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @doc """
  Hand a message to the session, to be answered in its own time.

  A cast rather than a call: the caller is the router, and waiting for an
  answer here is exactly what it must not do.
  """
  @spec say(session :: GenServer.server(), message :: Message.t()) :: :ok
  def say(session, %Message{} = message), do: GenServer.cast(session, {:say, message})

  @doc """
  What the session is holding, for tests and for the console.
  """
  @spec state(session :: GenServer.server()) :: map()
  def state(session), do: GenServer.call(session, :state)

  ### ==========================================================================
  ### Callback functions
  ### ==========================================================================

  @impl true
  def init(options) do
    state = %{
      key: Keyword.fetch!(options, :key),
      assistant: Keyword.fetch!(options, :assistant),
      id: Keyword.fetch!(options, :id),
      working_dir: Keyword.get(options, :working_dir),
      history: []
    }

    {:ok, state, Assistant.session_timeout()}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state, state, Assistant.session_timeout()}

  @impl true
  def handle_cast({:say, %Message{} = message}, state) do
    if Assistant.stop?(message.text) do
      Logger.info(%{what: "assistant_session_closed", channel: channel(state), reason: "asked"})

      reply(state, "Session closed. Authenticate again to carry on.")

      {:stop, :normal, state}
    else
      case answer(state, message) do
        {:carry_on, state} -> {:noreply, state, Assistant.session_timeout()}
        {:done, state} -> {:stop, :normal, state}
      end
    end
  end

  @impl true
  def handle_info(:timeout, state) do
    Logger.info(%{what: "assistant_session_expired", channel: channel(state), reason: "idle"})

    # Said, not just logged. A session that ends in silence looks from the
    # conversation like an assistant that stopped answering, and the next
    # message would be met with nothing at all.
    reply(state, "Session closed after #{minutes()} with nothing said. Authenticate to carry on.")

    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state, Assistant.session_timeout()}

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================

  # Asked and waited for here, in the conversation's own process. The assistant
  # holds its own deadline, so this waits for something that ends.
  defp answer(state, %Message{} = message) do
    # Redacted on the way into the history as well as on the way to a screen:
    # somebody who types the password again inside an open session should not
    # have it carried into every prompt after it.
    said = Assistant.redact(message).text
    history = remember(state.history, {:user, said})

    case Assistant.send_message(state.assistant, conversation(state), prompt(history),
           working_dir: state.working_dir
         ) do
      {:ok, answer} ->
        reply(state, answer)

        {:carry_on, %{state | history: remember(history, {:assistant, answer})}}

      {:error, reason} ->
        Logger.error(%{
          what: "assistant_reply_failed",
          assistant: state.assistant,
          reason: inspect(reason)
        })

        {outcome, text} = failure(state, reason)

        reply(state, text)

        {outcome, %{state | history: history}}
    end
  end

  # What the person waiting is told, and whether there is any point carrying on.
  #
  # A tool that refused said why, and that reason belongs to whoever asked:
  # hitting a usage limit is theirs to know, not something to hide behind an
  # apology. What is kept back is anything describing this machine to somebody
  # who cannot see it.
  defp failure(state, {:command_failed, said}) do
    if relayable?(said) do
      {:done, "#{state.assistant} could not answer: #{said}. Session closed."}
    else
      {:done, "Sorry, I could not answer that. Session closed."}
    end
  end

  defp failure(_state, {:executable_not_found, name}) do
    {:done, "#{name} is not installed here, so I cannot answer. Session closed."}
  end

  # Worth another go: the tool is there, and the next question may be smaller.
  defp failure(_state, :timeout) do
    {:carry_on, "That took too long to answer. Try again, or ask for less."}
  end

  defp failure(_state, _reason), do: {:done, "Sorry, I could not answer that. Session closed."}

  # A path is the one thing in a tool's own words that is nobody else's
  # business, so a message carrying one is kept back. A word with a slash in
  # the middle, such as a time zone, is not a path.
  @path_like ~r{(?:^|\s)[/~]\S}

  defp relayable?(said) do
    String.length(said) <= 300 and not Regex.match?(@path_like, said)
  end

  # How long it waited, in the words somebody would use for it.
  defp minutes do
    case div(Assistant.session_timeout(), 60_000) do
      0 -> "a while"
      1 -> "a minute"
      minutes -> "#{minutes} minutes"
    end
  end

  defp remember(history, turn), do: Enum.take(history ++ [turn], -Assistant.history_limit())

  defp prompt(history) do
    Enum.map_join(history, "\n", fn
      {:user, text} -> "User: #{text}"
      {:assistant, text} -> "Assistant: #{text}"
    end)
  end

  # A reply carries the assistant that wrote it and the session it belongs to,
  # so a reader can tell it from one a person typed at the dashboard.
  defp reply(state, text) do
    channel(state)
    |> Channel.send_message(conversation(state), text,
      sender: to_string(state.assistant),
      identifiers: [{"session", state.id}]
    )
    |> case do
      :ok ->
        :ok

      # A reply the channel refused reaches neither the person nor the
      # dashboard, since only a message that was sent is broadcast.
      {:error, reason} ->
        Logger.warning(%{
          what: "assistant_reply_not_sent",
          channel: channel(state),
          session: state.id,
          reason: inspect(reason)
        })

        :ok
    end
  end

  defp channel(%{key: {channel, _conversation}}), do: channel
  defp conversation(%{key: {_channel, conversation}}), do: conversation
end
