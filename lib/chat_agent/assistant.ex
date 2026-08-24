defmodule ChatAgent.Assistant do
  @moduledoc """
  Routes a prompt to the module configured for each assistant.

  An assistant is whatever can answer a person: today the `claude` command line
  tool, behind `ChatAgent.Assistant.Adapter`. Callers name the assistant they
  want and never the module, which is what lets a test swap one for a stub.

  `ChatAgent.Assistant.Router` is what decides when to ask one: it follows every
  channel, holds a session per conversation, and hands the reply back to the
  channel it came from.

  ## Configuration

      config :chat_agent, ChatAgent.Assistant,
        # Which assistant answers when a conversation names none.
        default: :claude,
        # What a conversation's password is checked against, hashed and salted
        # rather than written down. Set from ASSISTANT_SALTED_PASSWORD, and
        # generated with:
        #
        #     mix run -e 'IO.puts(Pbkdf2.hash_pwd_salt("hunter2"))'
        #
        # Without one, nobody is let in.
        salted_password: nil,
        # Where sessions work. The root is the one place a conversation may
        # pick from with --work-dir, and the default is what a conversation
        # that picks nothing gets: a name under the root, so the two are
        # written the same way and neither repeats the other.
        working_dir_root: "/srv/checkouts",
        working_dir: "the-one-repository",
        # How long a session survives with nothing said in it.
        session_timeout: :timer.minutes(5),
        # How many turns of a conversation are carried into the next prompt.
        history_limit: 20,
        adapters: [claude: ChatAgent.Assistant.Claude]
  """

  alias ChatAgent.Assistant.Router
  alias ChatAgent.Channel.Message

  require Logger

  @pubsub ChatAgent.PubSub
  @topic "assistant"

  @type assistant :: atom()

  @typedoc """
  What an authenticated message is asking for: a session, or one answer about
  the public URL.
  """
  @type action :: :open | :url | :renew

  # `/auth <password>`, with `/auth-claude <password>` naming the assistant and
  # one option after the password: `--work-dir <name>` naming what a session
  # works in, `--url` asking where this app is reachable, or `--renew` asking
  # for a new public URL. Quotes are optional and only needed for a password
  # with a space in it, since a password typed without them is the obvious
  # thing to type.
  #
  # The options are alternatives rather than a list, because they are: the two
  # that ask about the URL open no session, so there is nothing for a working
  # directory to belong to.
  #
  # Kept here rather than in the router, so that what opens a session and what
  # is hidden from the dashboard cannot drift apart: a form one of them knows
  # and the other does not is a password on a screen.
  @auth_regex ~r/^\/auth(?:-(?<assistant>[\w-]+))?\s+(?:"(?<quoted>[^"]*)"|(?<bare>\S+))(?:\s+(?:--work-dir\s+(?<work_dir>\S+)|--(?<action>url|renew)))?\s*$/

  # Closing a session by hand, which does what the idle timeout does, just now.
  @stop_command "/stop"

  @default_session_timeout :timer.minutes(5)
  @default_history_limit 20

  ### ==========================================================================
  ### Public functions
  ### ==========================================================================

  @doc """
  Send `prompt` to the module registered for `assistant`, and return its reply.

  Options are what the conversation asked for, such as `:working_dir`.
  """
  @spec send_message(
          assistant :: assistant(),
          conversation :: String.t(),
          prompt :: String.t(),
          options :: keyword()
        ) :: {:ok, String.t()} | {:error, term()}
  def send_message(assistant, conversation, prompt, options \\ []) do
    case adapter(assistant) do
      nil -> {:error, {:unknown_assistant, assistant}}
      module -> module.send_message(conversation, prompt, options)
    end
  end

  @doc """
  List every configured assistant and the module that answers for it.
  """
  @spec list() :: [{assistant(), module()}]
  def list, do: Keyword.get(config(), :adapters, [])

  @doc """
  Read an authentication attempt out of a message.

  Returns what it asked for: the password given, the assistant and working
  directory it named, with `nil` for each it left out, and what it is asking
  for.

  `:action` is `:open` for the attempt that opens a session, and `:url` or
  `:renew` for the two that ask about the public URL instead. Those two open
  nothing: they are the password being spent on one answer.
  """
  @spec authentication(text :: String.t()) ::
          {:ok,
           %{
             password: String.t(),
             assistant: String.t() | nil,
             work_dir: String.t() | nil,
             action: action()
           }}
          | :error
  def authentication(text) do
    case Regex.named_captures(@auth_regex, String.trim(text)) do
      nil ->
        :error

      captures ->
        {:ok,
         %{
           password: if(captures["bare"] == "", do: captures["quoted"], else: captures["bare"]),
           assistant: blank_to_nil(captures["assistant"]),
           work_dir: blank_to_nil(captures["work_dir"]),
           action: action(captures["action"])
         }}
    end
  end

  @doc """
  Resolve a working directory a conversation asked for.

  Whoever knows the password picks this, so it is resolved inside the one root
  that was configured and nowhere else: a name, a path that climbs out with
  `..`, and an absolute path elsewhere on the machine are all the same question,
  and the answer is where it lands.

  Returns `{:error, :not_offered}` when no root is configured, since the safe
  reading of no root is that no conversation chooses.
  """
  @spec working_dir(named :: String.t()) ::
          {:ok, String.t()} | {:error, :not_offered | :not_found}
  def working_dir(named), do: resolve(named, Keyword.get(config(), :working_dir_root))

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================

  # An assistant that works in exactly one place has no root, and the default
  # is then that place. Only the operator writes this: a conversation reaches
  # `working_dir/1`, which refuses without a root.
  defp resolve_default(configured, nil) do
    expanded = Path.expand(configured)

    if File.dir?(expanded), do: {:ok, expanded}, else: {:error, :not_found}
  end

  defp resolve_default(configured, root), do: resolve(configured, root)

  defp resolve(_named, nil), do: {:error, :not_offered}

  defp resolve(named, root) do
    root = Path.expand(root)
    resolved = Path.expand(named, root)

    if String.starts_with?(resolved, root <> "/") and File.dir?(resolved) do
      {:ok, resolved}
    else
      {:error, :not_found}
    end
  end

  @doc """
  Whether a message asks for the session to be closed.

  Kept beside `authentication/1` so that every word this understands is defined
  in one place.

  ## Examples

      iex> ChatAgent.Assistant.stop?("/stop")
      true

      iex> ChatAgent.Assistant.stop?("  /stop  ")
      true

      iex> ChatAgent.Assistant.stop?("/stopwatch")
      false
  """
  @spec stop?(text :: String.t()) :: boolean()
  def stop?(text), do: String.trim(text) == @stop_command

  @doc """
  Return a copy of `message` with any password in it replaced.

  Everything that shows or stores a message passes it through here first: a
  password typed into a chat would otherwise be read back off the dashboard, or
  out of the logs, by anyone who can see them.
  """
  @spec redact(Message.t()) :: Message.t()
  def redact(%Message{} = message), do: %{message | text: redact_text(message.text)}

  @doc """
  Replace a password in a piece of text.

  The form it was typed in is kept, so that what is read back is what was sent.

  ## Examples

      iex> ChatAgent.Assistant.redact_text("/auth hunter2")
      "/auth *****"

      iex> ChatAgent.Assistant.redact_text(~s(/auth "hunter 2"))
      ~s(/auth "*****")

      iex> ChatAgent.Assistant.redact_text("/auth-claude hunter2")
      "/auth-claude *****"

      iex> ChatAgent.Assistant.redact_text("/auth hunter2 --work-dir my-app-folder")
      "/auth ***** --work-dir my-app-folder"

      iex> ChatAgent.Assistant.redact_text("/auth hunter2 --url")
      "/auth ***** --url"

      iex> ChatAgent.Assistant.redact_text("/auth hunter2 --renew")
      "/auth ***** --renew"

      iex> ChatAgent.Assistant.redact_text("nothing to hide")
      "nothing to hide"
  """
  @spec redact_text(text :: String.t()) :: String.t()
  def redact_text(text) do
    Regex.replace(@auth_regex, String.trim(text), fn _matched,
                                                     assistant,
                                                     quoted,
                                                     bare,
                                                     work_dir,
                                                     action ->
      assistant = if assistant == "", do: "", else: "-#{assistant}"
      hidden = if bare == "" and quoted != nil, do: ~s("*****"), else: "*****"

      "/auth#{assistant} #{hidden}#{option(work_dir, action)}"
    end)
  end

  @doc """
  The assistant that answers when a conversation names none.
  """
  @spec default() :: assistant()
  def default, do: Keyword.get(config(), :default, :claude)

  @doc """
  The sessions open right now, keyed by the conversation each belongs to.

  Answers an empty map when no router is running, since a caller asking what is
  open cares whether anything is, not why nothing is.
  """
  @spec sessions() :: %{optional({atom(), String.t()}) => map()}
  def sessions do
    Router.sessions()
  catch
    :exit, _reason -> %{}
  end

  @doc """
  Subscribe the calling process to sessions opening and closing.

  Subscribers receive `{:assistant, {:session_opened, session}}` and
  `{:assistant, {:session_closed, key}}`.
  """
  @spec subscribe() :: :ok | {:error, {:already_registered, pid()}}
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, topic())

  @doc """
  Stop receiving session news.
  """
  @spec unsubscribe() :: :ok
  def unsubscribe, do: Phoenix.PubSub.unsubscribe(@pubsub, topic())

  @doc """
  The PubSub topic carrying sessions opening and closing.
  """
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc false
  @spec broadcast(event :: term()) :: :ok
  def broadcast(event), do: Phoenix.PubSub.broadcast(@pubsub, topic(), {:assistant, event})

  @doc """
  Where a session works when the conversation picked nothing.

  Written as a name under `:working_dir_root`, the same way a conversation
  writes it, so that one root governs both. An absolute path is accepted only
  when no root is configured, which is the case of an assistant that works in
  exactly one place.

  Answers `nil` when nothing is configured, leaving the assistant to run
  wherever this application does.
  """
  @spec default_working_dir() :: String.t() | nil
  def default_working_dir do
    case Keyword.get(config(), :working_dir) do
      nil ->
        nil

      configured ->
        case resolve_default(configured, Keyword.get(config(), :working_dir_root)) do
          {:ok, resolved} ->
            resolved

          {:error, reason} ->
            Logger.warning(%{
              what: "assistant_working_dir_unusable",
              working_dir: configured,
              reason: reason
            })

            nil
        end
    end
  end

  @doc """
  Whether any conversation could be answered at all.

  Without a password nothing opens a session, and without an assistant nothing
  answers one, so in either case the router has no work: the application starts
  it only when this is true.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: not is_nil(salted_password()) and list() != []

  @doc """
  The hash a conversation's password is checked against, or `nil` when none is
  configured.

  A hash rather than the password itself, so that reading the configuration,
  the logs, or a crash dump gives nobody a way in. Generate one with:

      mix run -e 'IO.puts(Pbkdf2.hash_pwd_salt("the password you will type"))'
  """
  @spec salted_password() :: String.t() | nil
  def salted_password, do: Keyword.get(config(), :salted_password)

  @doc """
  How long a session survives with nothing said in it.
  """
  @spec session_timeout() :: timeout()
  def session_timeout, do: Keyword.get(config(), :session_timeout, @default_session_timeout)

  @doc """
  How many turns are carried into the next prompt.
  """
  @spec history_limit() :: pos_integer()
  def history_limit, do: Keyword.get(config(), :history_limit, @default_history_limit)

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================

  defp adapter(assistant), do: Keyword.get(list(), assistant)

  # An attempt that named no option is the one that opens a session, which is
  # what `/auth` was for before there was anything else to ask for.
  defp action("url"), do: :url
  defp action("renew"), do: :renew
  defp action(_none), do: :open

  # Written back exactly as it was typed, since a redacted message is what is
  # read off the dashboard and out of the logs.
  defp option(work_dir, _action) when work_dir not in [nil, ""], do: " --work-dir #{work_dir}"
  defp option(_work_dir, action) when action not in [nil, ""], do: " --#{action}"
  defp option(_work_dir, _action), do: ""

  # A group that did not take part comes back empty rather than absent.
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp config, do: Application.get_env(:chat_agent, __MODULE__, [])
end
