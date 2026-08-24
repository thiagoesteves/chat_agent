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

  `:connected` is not the end of the sequence, because a URL that was
  registered successfully can stop working without anything here failing: the
  agent still runs, the registration still reads back correct, and the service
  quietly cannot reach it. So while connected, every channel is asked on
  `:health_interval` what delivery looks like from its side (see
  `c:ChatAgent.Channel.Adapter.webhook_health/0`), and a failing answer walks
  back up the same sequence:

      connected --(failing)--> registering   (told again, forced)
                --(failing)--> authenticating (a new URL entirely)

  That ladder is bounded. Re-registering is cheap and repairs the common case,
  a service still dialling an address the name has stopped pointing at, so it
  is tried twice; renewing costs the URL itself, so it
  is tried once; after that the failure is reported and left alone rather than
  turned into a machine that throws away a working tunnel every minute. A
  healthy answer clears the count.

  The check runs in a process of its own. It is a network call to somebody
  else's API, and this process answers `status/1` for every page that is
  watching.

  `renew/1` is that same return asked for rather than waited for: the agent is
  stopped and the sequence runs again, which is how a new public URL is
  obtained from a service that hands out whichever one it likes.

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
  alias ChatAgent.Channel.Health
  alias ChatAgent.Commander
  alias ChatAgent.Tunnel
  alias ChatAgent.Tunnel.Status

  require Logger

  @default_connect_timeout :timer.seconds(30)
  @default_max_backoff :timer.minutes(1)
  @default_health_interval :timer.minutes(1)
  @default_port 4000

  # How many forced re-registrations to try before the URL itself is suspected.
  @max_registrations 2

  # And how many URLs to throw away before concluding that the trouble is not
  # one this can fix.
  @max_renewals 1

  ### ==========================================================================
  ### Public functions
  ### ==========================================================================

  @doc """
  Start the state machine under a supervisor.

  Every option overrides the matching key read from `ChatAgent.Tunnel`'s
  configuration, which is what lets a test run one without configuring the
  application: `:provider`, `:port`, `:connect_timeout`, `:max_backoff` and
  `:health_interval`, plus a `:name` to register under when it is not the
  module's own.
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

  @doc """
  Throw the current tunnel away and open another one.

  The agent is stopped and the whole sequence runs again from
  `:authenticating`, which is what hands out a new URL: a free tunnel's URL is
  whatever the service gave it, and the only way to be given another is to ask
  again.

  Answers as soon as the sequence has been started rather than when it
  finishes, since opening a tunnel takes as long as the service takes and the
  URL is announced on the topic anyway.
  """
  @spec renew(server :: :gen_statem.server_ref()) :: :ok | {:error, :down}
  def renew(server \\ __MODULE__) do
    :gen_statem.call(server, :renew)
  catch
    :exit, _reason -> {:error, :down}
  end

  @doc """
  Ask every channel how delivery is going, now rather than at the next check.

  Repairs what it finds, the same way the interval check does, and starts the
  ladder over: somebody asking is somebody who has just changed something, so
  the attempts a failing tunnel had already spent are not counted against them.

  Answers `{:error, :not_connected}` where there is no URL to check, since a
  tunnel that has not opened one has nothing to ask about yet.
  """
  @spec check_health(server :: :gen_statem.server_ref()) ::
          :ok | {:error, :not_connected | :down}
  def check_health(server \\ __MODULE__) do
    :gen_statem.call(server, :check_health)
  catch
    :exit, _reason -> {:error, :down}
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
      health_interval: Keyword.get(config, :health_interval, @default_health_interval),
      exec_pid: nil,
      os_pid: nil,
      url: nil,
      buffer: "",
      attempts: 0,
      booted: false,
      error: nil,
      webhooks: %{},
      health: %{},
      registrations: 0,
      renewals: 0,
      force: false,
      since: DateTime.utc_now()
    }

    {:ok, :authenticating, data}
  end

  # --- Status, answerable in any state ---------------------------------------

  @impl true
  def handle_event({:call, from}, :status, state, data) do
    {:keep_state_and_data, [{:reply, from, status(state, data)}]}
  end

  # --- Renewing, which is the whole sequence again ----------------------------

  # The attempt count goes back to zero along with the agent, so the backoff a
  # failing tunnel had built up is not what somebody asking for a new URL waits
  # through: this is an attempt that was asked for, not one that retried.
  def handle_event({:call, from}, :renew, state, data) do
    Logger.info(%{what: "tunnel_renew_requested", provider: data.provider.name(), from: state})

    data = %{stop_agent(data) | url: nil, webhooks: %{}, health: %{}, attempts: 0, error: nil}
    reply = [{:reply, from, :ok}]

    # A transition to the state it is already in is not a transition: neither
    # the enter callback nor its timer would run again, and the renew would
    # wait out the backoff it just threw away. `:repeat_state` is that same
    # move made deliberately.
    if state == :authenticating do
      {:repeat_state, data, reply}
    else
      {:next_state, :authenticating, data, reply}
    end
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
    options = [force: data.force]

    webhooks =
      Map.new(Channel.list(), fn {channel, _module} ->
        {channel, register_webhook(channel, url, options)}
      end)

    data = %{data | webhooks: webhooks}

    if Enum.any?(webhooks, fn {_channel, result} -> retry_registration?(result) end) do
      {:repeat_state, retry(data, :registration_failed)}
    else
      # What was registered has not been delivered on yet, so the health it had
      # before this belongs to the registration that was replaced.
      {:next_state, :connected, %{data | attempts: 0, error: nil, force: false, health: %{}}}
    end
  end

  # --- Connected -------------------------------------------------------------

  def handle_event(:enter, old_state, :connected, data) do
    announce(old_state, :connected, data, %{
      webhooks: Map.new(data.webhooks, fn {channel, result} -> {channel, inspect(result)} end)
    })

    {:keep_state_and_data, [{:state_timeout, data.health_interval, :check_health}]}
  end

  # --- Delivery health, which only a connected tunnel has to answer for -------

  # The check is started here and re-armed in the same breath, rather than when
  # its answer arrives: an answer that never comes is a channel's API being
  # slow, and it should delay the next check rather than end them.
  def handle_event(:state_timeout, :check_health, :connected, data) do
    start_health_check(data)

    {:keep_state_and_data, [{:state_timeout, data.health_interval, :check_health}]}
  end

  def handle_event({:call, from}, :check_health, :connected, data) do
    start_health_check(data)

    {:keep_state, %{data | registrations: 0, renewals: 0},
     [{:reply, from, :ok}, {:state_timeout, data.health_interval, :check_health}]}
  end

  # Nothing is open to check, which is not the same as everything being well.
  def handle_event({:call, from}, :check_health, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_connected}}]}
  end

  # Reports are matched against the URL they were asked about, so an answer
  # about a tunnel that has since been replaced is not read as news about this
  # one. Anything that does not match falls through to the clause that ignores
  # what this server no longer tracks.
  def handle_event(:info, {:health, url, results}, :connected, %{url: url} = data) do
    data = report_health(data, results)

    case failing(data) do
      [] -> {:keep_state, %{data | registrations: 0, renewals: 0, error: clear(data.error)}}
      failing -> repair(data, failing)
    end
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

  defp register_webhook(channel, url, options) do
    result = Channel.register_webhook(channel, url, options)

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

  # Asked from a process of its own: this is a call to somebody else's API, and
  # this process is what every open page asks for its status. A channel that
  # has already said it cannot answer is not asked again while this URL stands,
  # and the URL travels with the question so a late answer about a tunnel that
  # has been replaced can be recognised as one.
  defp start_health_check(%{url: url, health: health}) do
    server = self()

    channels =
      Enum.reject(Channel.list(), fn {channel, _module} ->
        match?({:error, :not_supported}, Map.get(health, channel))
      end)

    spawn(fn ->
      results =
        Map.new(channels, fn {channel, _module} ->
          {channel, Channel.webhook_health(channel)}
        end)

      send(server, {:health, url, results})
    end)
  end

  defp report_health(data, results) do
    for {channel, result} <- results, changed?(data.health[channel], result) do
      log_health(channel, result)
    end

    data = %{data | health: Map.merge(data.health, results)}

    Tunnel.broadcast(status(:connected, data))

    data
  end

  # A check answering the same thing it answered a minute ago is not news. What
  # a report is compared on is what it says, rather than the whole of it: every
  # report carries the time it was read, and no two of those are ever equal.
  defp changed?(previous, current), do: summarise(previous) != summarise(current)

  defp summarise({:ok, %Health{} = health}), do: {health.state, health.pending, health.last_error}
  defp summarise(other), do: other

  defp log_health(channel, {:ok, %Health{state: :failing} = health}) do
    Logger.warning(%{
      what: "channel_delivery_failing",
      channel: channel,
      pending: health.pending,
      last_error: health.last_error,
      last_error_at: health.last_error_at,
      details: health.details
    })
  end

  defp log_health(channel, {:ok, %Health{} = health}) do
    Logger.info(%{
      what: "channel_delivery_checked",
      channel: channel,
      state: health.state,
      pending: health.pending
    })
  end

  defp log_health(channel, {:error, reason}) do
    Logger.info(%{what: "channel_delivery_unknown", channel: channel, reason: inspect(reason)})
  end

  defp failing(data) do
    for {channel, result} <- data.health,
        failing?(channel, result, data.url),
        do: channel
  end

  # A check that could not be made says nothing about delivery: what is down
  # may be the service being asked, and no amount of re-registering with it
  # would help.
  defp failing?(_channel, {:error, _reason}, _base_url), do: false

  # A service pointed somewhere else is as unreachable as one that cannot
  # deliver, and it is the same repair: tell it again where to call.
  defp failing?(channel, {:ok, %Health{} = health}, base_url) do
    Health.failing?(health) or health.url != Channel.webhook_url(channel, base_url)
  end

  # The ladder: tell the service again, then throw the URL away, then stop and
  # say so. Each rung is only worth climbing while the one below it has been
  # spent, and the count is cleared by a healthy answer rather than by time.
  defp repair(data, failing) do
    cond do
      data.registrations < @max_registrations ->
        Logger.warning(%{
          what: "tunnel_webhook_repairing",
          channels: failing,
          attempt: data.registrations + 1,
          url: data.url
        })

        {:next_state, :registering,
         %{data | registrations: data.registrations + 1, force: true, attempts: 0}}

      data.renewals < @max_renewals ->
        Logger.warning(%{
          what: "tunnel_renewing_after_failed_delivery",
          channels: failing,
          url: data.url
        })

        # A URL nobody can deliver to is worth no more than the next one, and
        # the next one is registered from scratch: the cheap repair is worth
        # trying again on it.
        data = %{
          stop_agent(data)
          | url: nil,
            webhooks: %{},
            health: %{},
            attempts: 0,
            registrations: 0,
            renewals: data.renewals + 1
        }

        {:next_state, :authenticating, data}

      true ->
        # Everything this machine can do has been done, and doing it again on
        # a timer would only keep throwing away tunnels that are not the
        # problem. The checks carry on, so a failure that ends elsewhere is
        # still noticed, and the status says why nothing more is happening.
        if data.error != :delivery_failing do
          Logger.error(%{
            what: "tunnel_delivery_unrepaired",
            channels: failing,
            url: data.url
          })
        end

        {:keep_state, %{data | error: :delivery_failing}}
    end
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

  # Nothing to stop between attempts, which is where a renew can arrive.
  defp stop_agent(%{os_pid: nil} = data), do: data

  defp stop_agent(%{os_pid: os_pid} = data) do
    Commander.stop(os_pid)

    %{data | exec_pid: nil, os_pid: nil}
  end

  defp retry(data, error), do: %{data | attempts: data.attempts + 1, error: error}

  # Delivery being well again is the answer to the only error this reports
  # without a step of the sequence having failed. Anything else it is holding
  # was put there by something this check knows nothing about.
  defp clear(:delivery_failing), do: nil
  defp clear(error), do: error

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
      health: data.health,
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
