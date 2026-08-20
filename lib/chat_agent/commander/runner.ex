defmodule ChatAgent.Commander.Runner do
  @moduledoc """
  Runs one command in a process of its own, and answers with what it said.

  A command run for its output is a conversation, not a call: chunks of output
  arrive as messages, the run ends as another, and a deadline has to be held
  while both are outstanding. Waiting for that in the caller means a `receive`
  inside a process that belongs to something else. In a `GenServer` that is
  worse than it looks: the server stops answering for as long as the command
  takes, every message that arrives meanwhile queues behind the one being
  waited for, and anything the run says after the answer was given is left in a
  mailbox that is not its own.

  So the run gets a process. This one owns the OS process, holds the deadline,
  and answers the caller once:

      {:ok, output}                             # it finished, and this is all it said
      {:error, {:exit_status, status, output}}  # it ran and failed
      {:error, :timeout}                        # it overran, and was stopped
      {:error, reason}                          # it never started, or ended otherwise

  The caller still waits, since a command is asked for by somebody who wants
  its answer, but it waits in a `GenServer.call/3`, with none of the run's own
  messages ever reaching it.

  ## What holds it together

  The command runs under `ChatAgent.Commander.run_link/2`, so erlexec links it
  to this process and kills it if this process goes. Exits are trapped, which
  is what turns a command failing into a message here rather than an exit here,
  and it is why nothing needs a `terminate/2` killing the command by hand.

  The caller is monitored, for the case it has nothing to do with: a caller
  that dies mid-run leaves nobody to answer, so this process stops, and the
  link takes the command with it.
  """

  use GenServer, restart: :temporary

  alias ChatAgent.Commander

  @supervisor ChatAgent.Commander.RunnerSupervisor

  @default_timeout :timer.minutes(2)

  @type result :: {:ok, String.t()} | {:error, term()}

  ### ==========================================================================
  ### Public functions
  ### ==========================================================================

  @doc """
  Run `command`, and answer with everything it said.

  Options:

    * `:timeout` - how long the command may take before it is stopped and
      `{:error, :timeout}` is answered. Two minutes by default.
    * `:cd` - the directory to run in. Where the caller stands, by default.
    * `:supervisor` - what to start the run under, which is the application's
      own runner supervisor unless something else is passed.

  stderr is folded into stdout, so the output is one stream, in the order the
  command said it, and it is answered exactly as it arrived: whitespace and
  all, since what to make of it belongs to whoever asked.
  """
  @spec run(command :: Commander.Adapter.command(), options :: keyword()) :: result()
  def run(command, options \\ []) do
    {supervisor, options} = Keyword.pop(options, :supervisor, @supervisor)

    case DynamicSupervisor.start_child(
           supervisor,
           {__MODULE__, Keyword.merge(options, command: command, owner: self())}
         ) do
      {:ok, runner} -> await(runner)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec start_link(options :: keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  ### ==========================================================================
  ### Callback functions
  ### ==========================================================================

  @impl true
  def init(options) do
    # Linked to the command, so it failing arrives as a message rather than as
    # an exit here: a command that exits non-zero is a result, not a crash.
    Process.flag(:trap_exit, true)

    state = %{
      command: Keyword.fetch!(options, :command),
      owner: Keyword.fetch!(options, :owner),
      timeout: Keyword.get(options, :timeout) || @default_timeout,
      cd: Keyword.get(options, :cd),
      exec_pid: nil,
      os_pid: nil,
      output: [],
      waiting: nil,
      result: nil
    }

    Process.monitor(state.owner)

    {:ok, state, {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, state) do
    options = [:stdout, {:stderr, :stdout}] ++ working_dir(state)

    case Commander.run_link(state.command, options) do
      {:ok, exec_pid, os_pid} ->
        Process.send_after(self(), :deadline, state.timeout)

        {:noreply, %{state | exec_pid: exec_pid, os_pid: os_pid}}

      {:error, reason} ->
        finish(state, {:error, reason})

      other ->
        finish(state, {:error, other})
    end
  end

  # Answered as soon as there is an answer, which is usually after this arrives
  # and occasionally before it: a command can finish while the caller is still
  # on its way here.
  @impl true
  def handle_call(:await, from, %{result: nil} = state) do
    {:noreply, %{state | waiting: from}}
  end

  def handle_call(:await, _from, %{result: result} = state) do
    {:stop, :normal, result, state}
  end

  @impl true
  def handle_info({:stdout, os_pid, chunk}, %{os_pid: os_pid} = state) do
    {:noreply, %{state | output: [chunk | state.output]}}
  end

  def handle_info({:EXIT, exec_pid, :normal}, %{exec_pid: exec_pid} = state) do
    finish(state, {:ok, said(state)})
  end

  def handle_info({:EXIT, exec_pid, {:exit_status, status}}, %{exec_pid: exec_pid} = state) do
    finish(state, {:error, {:exit_status, status, said(state)}})
  end

  def handle_info({:EXIT, exec_pid, reason}, %{exec_pid: exec_pid} = state) do
    finish(state, {:error, reason})
  end

  def handle_info(:deadline, state) do
    # Stopped rather than left to run: the link would take it down with this
    # process, but this process is not going away until it has answered.
    Commander.stop(state.os_pid)

    finish(state, {:error, :timeout})
  end

  # Nobody left to answer, so there is nothing to run for. The command goes
  # with this process, since erlexec kills what it linked.
  def handle_info({:DOWN, _reference, :process, owner, _reason}, %{owner: owner} = state) do
    {:stop, :normal, state}
  end

  # Anything else, which is a run this process is no longer waiting on: output
  # from a command stopped at its deadline, or the exit of one already answered
  # for. A shutdown is not among them, since `:gen_server` handles the parent's
  # exit itself, before any of this.
  def handle_info(_message, state), do: {:noreply, state}

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================

  # A run that stopped without answering is answered for, rather than left to
  # take the caller down with it: the caller asked for a command's result, and
  # this is one of the ways there is no result.
  defp await(runner) do
    GenServer.call(runner, :await, :infinity)
  catch
    :exit, reason -> {:error, {:runner_stopped, reason}}
  end

  # One answer, whether or not anybody has asked for it yet.
  defp finish(%{waiting: nil} = state, result), do: {:noreply, %{state | result: result}}

  defp finish(state, result) do
    GenServer.reply(state.waiting, result)

    {:stop, :normal, state}
  end

  defp said(state), do: state.output |> Enum.reverse() |> Enum.join()

  defp working_dir(%{cd: nil}), do: []
  defp working_dir(%{cd: path}), do: [{:cd, path}]
end
