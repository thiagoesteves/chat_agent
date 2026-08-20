defmodule ChatAgent.Commander.RunnerTest do
  use ExUnit.Case, async: false

  import Mox

  alias ChatAgent.Commander.Runner
  alias ChatAgent.CommanderMock

  # The run happens in a process of its own, so the mock has to answer calls
  # from any process rather than only from this one.
  setup :set_mox_global
  setup :verify_on_exit!

  # Stands in for erlexec: the mock answers as `run_link/2` does, and every
  # message a linked run would send is sent from inside it, to the runner, and
  # before the test is told the command ran. That order is what lets a test say
  # something is true once it has seen `{:ran, ...}`.
  defp expect_run(messages, os_pid \\ 4242) do
    test_process = self()

    expect(CommanderMock, :run_link, fn command, options ->
      runner = self()
      Enum.each(messages, fn message -> send(runner, message.(os_pid, runner)) end)
      send(test_process, {:ran, command, options})

      {:ok, runner, os_pid}
    end)
  end

  defp stdout(chunk), do: fn os_pid, _runner -> {:stdout, os_pid, chunk} end
  defp finished, do: fn _os_pid, runner -> {:EXIT, runner, :normal} end
  defp exited(status), do: fn _os_pid, runner -> {:EXIT, runner, {:exit_status, status}} end

  describe "run/2" do
    test "answers with everything the command said, in the order it said it" do
      expect_run([stdout("one "), stdout("reply "), stdout("in chunks\n"), finished()])

      assert {:ok, "one reply in chunks\n"} = Runner.run(["echo", "hello"])

      assert_receive {:ran, ["echo", "hello"], options}
      # One stream, so nothing the command wrote to stderr is lost or reordered.
      assert :stdout in options
      assert {:stderr, :stdout} in options
    end

    test "answers a command that said nothing at all" do
      expect_run([finished()])

      assert {:ok, ""} = Runner.run(["true"])
    end

    test "answers a command that failed with its status and what it said" do
      expect_run([stdout("nope\n"), exited(256)])

      # Untouched, whitespace and all: what to make of it belongs to the caller.
      assert {:error, {:exit_status, 256, "nope\n"}} = Runner.run(["false"])
    end

    test "answers a run that ended some other way with how it ended" do
      expect_run([fn _os_pid, runner -> {:EXIT, runner, :noproc} end])

      assert {:error, :noproc} = Runner.run(["true"])
    end

    test "stops a command that outlives its deadline, rather than waiting on it" do
      test_process = self()

      # Never says anything, and never finishes.
      expect(CommanderMock, :run_link, fn _command, _options -> {:ok, self(), 4242} end)

      expect(CommanderMock, :stop, fn os_pid ->
        send(test_process, {:stopped, os_pid})
        :ok
      end)

      assert {:error, :timeout} = Runner.run(["sleep", "60"], timeout: 50)

      # Stopped rather than left running: nothing else would have.
      assert_receive {:stopped, 4242}
    end

    test "runs where it was told to" do
      expect_run([finished()])

      assert {:ok, ""} = Runner.run(["true"], cd: "/srv/checkouts/my-app-folder")

      assert_receive {:ran, _command, options}
      assert {:cd, "/srv/checkouts/my-app-folder"} in options
    end

    test "runs where the caller stands when it was told nowhere" do
      expect_run([finished()])

      assert {:ok, ""} = Runner.run(["true"])

      assert_receive {:ran, _command, options}
      refute Enum.any?(options, &match?({:cd, _path}, &1))
    end

    test "ignores anything that is not this run" do
      stranger = spawn(fn -> :ok end)

      expect_run([
        stdout("mine\n"),
        # Another run's output, another run's exit, and a message from nowhere
        # in particular.
        fn _os_pid, _runner -> {:stdout, 9999, "not mine\n"} end,
        fn _os_pid, _runner -> {:EXIT, stranger, :normal} end,
        fn _os_pid, _runner -> :unrelated end,
        finished()
      ])

      assert {:ok, "mine\n"} = Runner.run(["true"])
    end

    test "answers rather than raising when the run could not be started" do
      {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one, max_children: 0)

      assert {:error, :max_children} = Runner.run(["true"], supervisor: supervisor)
    end

    test "passes back a command that could not be started" do
      expect(CommanderMock, :run_link, fn _command, _options -> {:error, :enoent} end)

      assert {:error, :enoent} = Runner.run(["definitely-not-installed"])
    end

    test "reports an answer it does not recognise as a failure" do
      expect(CommanderMock, :run_link, fn _command, _options -> :something_else end)

      assert {:error, :something_else} = Runner.run(["true"])
    end

    @tag :capture_log
    test "answers rather than taking the caller down when the run itself fails" do
      expect(CommanderMock, :run_link, fn _command, _options -> raise "erlexec fell over" end)

      # The caller asked for a command's result, and this is one of the ways
      # there is no result: an exit here would take the conversation with it.
      assert {:error, {:runner_stopped, _reason}} = Runner.run(["true"])
    end

    test "stops the run when the caller it was answering has gone" do
      test_process = self()

      expect(CommanderMock, :run_link, fn _command, _options ->
        send(test_process, {:running, self()})

        {:ok, self(), 4242}
      end)

      caller = spawn(fn -> Runner.run(["sleep", "60"], timeout: :timer.minutes(1)) end)

      assert_receive {:running, runner}
      reference = Process.monitor(runner)

      Process.exit(caller, :kill)

      # The command goes with it, since erlexec kills what it linked.
      assert_receive {:DOWN, ^reference, :process, ^runner, :normal}
    end
  end

  describe "the run's own process" do
    test "answers a caller that arrives after the command has already finished" do
      expect_run([stdout("quick\n"), finished()])

      {:ok, runner} = Runner.start_link(command: ["echo"], owner: self())

      # Everything the run said was said before the mock returned, so by the
      # time this arrives there is an answer waiting for a question.
      assert_receive {:ran, _command, _options}

      assert {:ok, "quick\n"} = GenServer.call(runner, :await)
    end
  end
end
