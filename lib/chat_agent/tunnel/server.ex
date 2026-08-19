defmodule ChatAgent.Tunnel.Server do
  @moduledoc """
  Keeps a public URL open, as a state machine over the tunnel agent's process.

  Opening a tunnel is a sequence, not a single call: prove the agent's
  credentials, run it, wait for it to report the URL it was given, tell every
  channel where its webhook now lives. Any step can fail, and the agent can die
  at any point afterwards, at which point the whole sequence runs again. That
  is a state machine, so this is `:gen_statem` rather than a `GenServer` with a
  status field:

      authenticating -> connecting -> registering -> connected
             ^-------------------------------------------|
                    (agent exited, or a step failed)

  Every failure returns to `:authenticating` after a backoff that grows with
  the number of consecutive attempts and is capped by `:max_backoff`, so a
  service that is down does not turn into a spin.

  The agent runs under `ChatAgent.Commander.run_link/2`, which links it to this
  process: with `trap_exit` set, the agent going down arrives as a message here
  rather than as an orphaned OS process, and this process going down takes the
  agent with it, which is why nothing here has to stop the agent on shutdown.

  Reading the agent's stdout is how the URL is discovered, so output is
  buffered until a full line is available and each line is handed to the
  provider's `c:ChatAgent.Tunnel.Provider.Adapter.parse/1`.
  """

  @behaviour :gen_statem

  alias ChatAgent.Channel
  alias ChatAgent.Commander
  alias ChatAgent.Tunnel
  alias ChatAgent.Tunnel.Status

  require Logger

  @default_connect_timeout :timer.seconds(30)
  @default_max_backoff :timer.minutes(1)
  @default_port 4000

  ### ==========================================================================
  ### Public functions
  ### ==========================================================================

  @doc """
  Start the state machine under a supervisor.

  Every option overrides the matching key read from `ChatAgent.Tunnel`'s
  configuration, which is what lets a test run one without configuring the
  application: `:provider`, `:port`, `:connect_timeout` and `:max_backoff`, plus
  a `:name` to register under when it is not the module's own.
  """
  @spec start_link(options :: keyword()) :: :gen_statem.start_ret()
  def start_link(options) do
    {name, options} = Keyword.pop(options, :name, __MODULE__)

    :gen_statem.start_link({:local, name}, __MODULE__, options, [])
  end

  @doc """
  The child specification a supervisor starts this from.

  Written out because `:gen_statem` has no `use` to generate one, and the id is
  the registered name so two tunnels could run side by side.
  """
  @spec child_spec(options :: keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    %{
      id: Keyword.get(options, :name, __MODULE__),
      start: {__MODULE__, :start_link, [options]}
    }
  end

  @doc """
  The URL the tunnel has open, if it has one.
  """
  @spec url(server :: :gen_statem.server_ref()) :: {:ok, String.t()} | {:error, :not_connected}
  def url(server \\ __MODULE__) do
    case status(server) do
      %Status{url: nil} -> {:error, :not_connected}
      %Status{url: url} -> {:ok, url}
    end
  end

  @doc """
  What the tunnel is doing right now.

  Answers `:down` rather than raising when the server is not running, since a
  caller asking for the URL cares whether one exists, not why it does not.
  """
  @spec status(server :: :gen_statem.server_ref()) :: Status.t()
  def status(server \\ __MODULE__) do
    :gen_statem.call(server, :status)
  catch
    :exit, _reason -> %Status{state: :down}
  end

  ### ==========================================================================
  ### Callback functions
  ### ==========================================================================

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(options) do
    # Linked to the agent, so its exit has to arrive as a message rather than
    # take this process down with it.
    Process.flag(:trap_exit, true)

    config = Keyword.merge(Tunnel.config(), options)

    data = %{
      provider: Keyword.fetch!(config, :provider),
      port: Keyword.get(config, :port) || default_port(),
      connect_timeout: Keyword.get(config, :connect_timeout, @default_connect_timeout),
      max_backoff: Keyword.get(config, :max_backoff, @default_max_backoff),
      exec_pid: nil,
      os_pid: nil,
      url: nil,
      buffer: "",
      attempts: 0,
      booted: false,
      error: nil,
      webhooks: %{},
      since: DateTime.utc_now()
    }

    {:ok, :authenticating, data}
  end

  # --- Status, answerable in any state ---------------------------------------

  @impl true
  def handle_event({:call, from}, :status, state, data) do
    {:keep_state_and_data, [{:reply, from, status(state, data)}]}
  end

  # --- Authenticating --------------------------------------------------------

  def handle_event(:enter, old_state, :authenticating, data) do
    delay = backoff(data)

    # `:gen_statem` enters its first state with no previous one to report,
    # which would otherwise read in the log as a retry of itself.
    from = if data.booted, do: old_state, else: :none

    announce(from, :authenticating, data, %{retry_in_ms: delay})

    {:keep_state, %{data | booted: true}, [{:state_timeout, delay, :authenticate}]}
  end

  def handle_event(:state_timeout, :authenticate, :authenticating, data) do
    case data.provider.authenticate() do
      :ok ->
        {:next_state, :connecting, %{data | attempts: 0, error: nil}}

      {:error, reason} ->
        Logger.error(%{
          what: "tunnel_authentication_failed",
          provider: data.provider.name(),
          reason: inspect(reason)
        })

        {:repeat_state, retry(data, reason)}
    end
  end

  # --- Connecting ------------------------------------------------------------

  def handle_event(:enter, old_state, :connecting, data) do
    announce(old_state, :connecting, data)

    # The agent is started from its own event rather than from here, because a
    # state enter callback cannot move to another state and starting it can
    # fail.
    {:keep_state_and_data, [{:state_timeout, 0, :start}]}
  end

  def handle_event(:state_timeout, :start, :connecting, data) do
    command = data.provider.command(data.port)

    case Commander.run_link(command, [:stdout, :stderr]) do
      {:ok, exec_pid, os_pid} ->
        Logger.info(%{
          what: "tunnel_agent_started",
          provider: data.provider.name(),
          port: data.port,
          os_pid: os_pid
        })

        data = %{data | exec_pid: exec_pid, os_pid: os_pid, buffer: ""}

        {:keep_state, data, [{:state_timeout, data.connect_timeout, :timeout}]}

      reason ->
        Logger.error(%{
          what: "tunnel_agent_start_failed",
          provider: data.provider.name(),
          reason: inspect(reason)
        })

        {:next_state, :authenticating, retry(data, reason)}
    end
  end

  def handle_event(:state_timeout, :timeout, :connecting, data) do
    Logger.error(%{
      what: "tunnel_connect_timeout",
      provider: data.provider.name(),
      timeout: data.connect_timeout
    })

    {:next_state, :authenticating, data |> stop_agent() |> retry(:connect_timeout)}
  end

  # --- Registering -----------------------------------------------------------

  def handle_event(:enter, old_state, :registering, data) do
    delay = backoff(data)

    announce(old_state, :registering, data, %{retry_in_ms: delay})

    {:keep_state_and_data, [{:state_timeout, delay, :register}]}
  end

  def handle_event(:state_timeout, :register, :registering, %{url: url} = data) do
    webhooks =
      Map.new(Channel.list(), fn {channel, _module} ->
        {channel, register_webhook(channel, url)}
      end)

    data = %{data | webhooks: webhooks}

    if Enum.any?(webhooks, fn {_channel, result} -> retry_registration?(result) end) do
      {:repeat_state, retry(data, :registration_failed)}
    else
      {:next_state, :connected, %{data | attempts: 0, error: nil}}
    end
  end

  # --- Connected -------------------------------------------------------------

  def handle_event(:enter, old_state, :connected, data) do
    announce(old_state, :connected, data, %{
      webhooks: Map.new(data.webhooks, fn {channel, result} -> {channel, inspect(result)} end)
    })

    :keep_state_and_data
  end

  # --- The agent's output and its exit, in every state it can run in ----------

  def handle_event(:info, {stream, os_pid, chunk}, state, %{os_pid: os_pid} = data)
      when stream in [:stdout, :stderr] do
    {lines, buffer} = lines(data.buffer <> to_string(chunk))

    handle_output(lines, state, %{data | buffer: buffer})
  end

  def handle_event(:info, {:EXIT, exec_pid, reason}, _state, %{exec_pid: exec_pid} = data) do
    Logger.warning(%{
      what: "tunnel_agent_exited",
      provider: data.provider.name(),
      reason: inspect(reason)
    })

    data = %{data | exec_pid: nil, os_pid: nil, url: nil, webhooks: %{}}

    {:next_state, :authenticating, retry(data, {:agent_exited, reason})}
  end

  # Output from an agent that has already been replaced, and the exit of a
  # process this server no longer tracks, are both expected: an agent that is
  # stopped still gets to say so.
  def handle_event(:info, _message, _state, _data), do: :keep_state_and_data

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================

  # A URL is the only line that changes what this server does. Anything else
  # the provider recognises is logged where it is worth reading, and a failing
  # agent is left to exit rather than being torn down mid-sentence: the exit is
  # what starts the cycle again.
  defp handle_output([], _state, data), do: {:keep_state, data}

  defp handle_output([line | rest], state, data) do
    case data.provider.parse(line) do
      {:ok, url} when url != data.url ->
        Logger.info(%{what: "tunnel_url_received", provider: data.provider.name(), url: url})

        {:next_state, :registering, %{data | url: url, attempts: 0}}

      {:error, reason} ->
        Logger.error(%{
          what: "tunnel_agent_error",
          provider: data.provider.name(),
          reason: inspect(reason)
        })

        handle_output(rest, state, %{data | error: reason})

      _ignored_or_unchanged ->
        Logger.debug(%{what: "tunnel_agent_output", provider: data.provider.name(), line: line})

        handle_output(rest, state, data)
    end
  end

  defp register_webhook(channel, url) do
    result = Channel.register_webhook(channel, url)

    case result do
      {:ok, outcome} ->
        Logger.info(%{
          what: "tunnel_webhook_#{outcome}",
          channel: channel,
          url: Channel.webhook_url(channel, url)
        })

      {:error, reason} ->
        Logger.warning(%{
          what: "tunnel_webhook_not_registered",
          channel: channel,
          reason: inspect(reason)
        })
    end

    result
  end

  # A channel whose service has no API for this says so once and is not asked
  # again, since retrying cannot change the answer. Anything else is worth
  # another attempt.
  defp retry_registration?({:ok, _outcome}), do: false
  defp retry_registration?({:error, :not_supported}), do: false
  defp retry_registration?({:error, _reason}), do: true

  # Splits complete lines off the buffer, keeping whatever follows the last
  # newline: a chunk of output is not a line, and a line can arrive in pieces.
  defp lines(buffer) do
    {rest, complete} =
      buffer
      |> String.split("\n")
      |> List.pop_at(-1)

    {Enum.reject(complete, &(&1 == "")), rest}
  end

  defp stop_agent(%{os_pid: os_pid} = data) do
    Commander.stop(os_pid)

    %{data | exec_pid: nil, os_pid: nil}
  end

  defp retry(data, error), do: %{data | attempts: data.attempts + 1, error: error}

  # Grows with each consecutive failure and starts at zero, so the first
  # attempt of a cycle runs immediately.
  defp backoff(%{attempts: attempts, max_backoff: max_backoff}) do
    min(2 * attempts * 1_000, max_backoff)
  end

  # One line per transition, including a repeated state, which is what a retry
  # is: `from` and `to` being equal is how a retry reads in the log.
  defp announce(old_state, state, data, extra \\ %{}) do
    Logger.info(
      Map.merge(
        %{
          what: "tunnel_state_changed",
          provider: data.provider.name(),
          from: old_state,
          to: state,
          attempt: data.attempts,
          url: data.url
        },
        extra
      )
    )

    Tunnel.broadcast(status(state, data))
  end

  defp status(state, data) do
    %Status{
      state: state,
      url: data.url,
      provider: data.provider,
      error: data.error,
      webhooks: data.webhooks,
      since: data.since
    }
  end

  # The tunnel forwards to whatever the endpoint is listening on, so the port
  # is read from it rather than configured twice. What it bound is the truth
  # rather than what it was asked for: `port: 0` asks the operating system to
  # pick one, and only the endpoint knows which it got.
  defp default_port do
    case ChatAgentWeb.Endpoint.server_info(:http) do
      {:ok, {_ip, port}} -> port
      _no_listener -> configured_port()
    end
  end

  # No listener to ask, which is how the test environment runs.
  defp configured_port do
    :chat_agent
    |> Application.get_env(ChatAgentWeb.Endpoint, [])
    |> Keyword.get(:http, [])
    |> Keyword.get(:port, @default_port)
  end
end
