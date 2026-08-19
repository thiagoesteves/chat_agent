defmodule ChatAgent.Assistant.ClaudeTest do
  use ExUnit.Case, async: false

  import Mox

  alias ChatAgent.Assistant.Claude
  alias ChatAgent.CommanderMock

  setup :verify_on_exit!

  setup do
    configured = Application.get_env(:chat_agent, Claude)
    on_exit(fn -> Application.put_env(:chat_agent, Claude, configured) end)

    # Something that exists on any machine running these tests, so what is
    # under test is the adapter rather than whether a tool is installed.
    Application.put_env(:chat_agent, Claude, executable: "sh", timeout: 1_000)

    :ok
  end

  # Stands in for erlexec: the mock answers as `run/2` does, and the messages a
  # watched process would send arrive from here, in this process, which is
  # where the adapter is waiting for them.
  defp expect_run(messages, os_pid \\ 4242) do
    test_process = self()

    expect(CommanderMock, :run, fn command, options ->
      send(test_process, {:ran, command, options})
      Enum.each(messages, fn message -> send(test_process, message.(os_pid)) end)

      {:ok, self(), os_pid}
    end)
  end

  defp stdout(chunk), do: fn os_pid -> {:stdout, os_pid, chunk} end
  defp finished, do: fn os_pid -> {:DOWN, os_pid, :process, self(), :normal} end

  defp exited(status),
    do: fn os_pid -> {:DOWN, os_pid, :process, self(), {:exit_status, status}} end

  describe "send_message/2" do
    test "runs the tool with the prompt, and returns what it printed" do
      expect_run([stdout("I am well.\n"), finished()])

      assert {:ok, "I am well."} = Claude.send_message("123456", "How are you?")

      assert_receive {:ran, command, options}
      # An argument list, not a command line: no shell reads the prompt.
      assert [executable, "-p", "How are you?"] = command
      assert String.ends_with?(executable, "/sh")
      # Watched, so the run has a process id this can stop when it overruns.
      assert :monitor in options
      assert {:stderr, :stdout} in options
    end

    test "joins output that arrived in pieces, in the order it was said" do
      expect_run([stdout("one "), stdout("reply "), stdout("in chunks\n"), finished()])

      assert {:ok, "one reply in chunks"} = Claude.send_message("123456", "hello")
    end

    test "answers an empty reply rather than failing on it" do
      expect_run([finished()])

      assert {:ok, ""} = Claude.send_message("123456", "hello")
    end

    test "says the tool is missing, rather than what the failure looked like" do
      Application.put_env(:chat_agent, Claude, executable: "definitely-not-installed")

      # Nothing is run at all: the tool is looked for first.
      assert {:error, {:executable_not_found, "definitely-not-installed"}} =
               Claude.send_message("123456", "hello")
    end

    test "carries the tool's own words when it refuses" do
      expect_run([stdout("Invalid API key\n"), exited(256)])

      assert {:error, {:command_failed, "Invalid API key"}} = Claude.send_message("123456", "hi")
    end

    test "falls back to the exit code when it said nothing at all" do
      # 768 is exit code 3, as a wait status.
      expect_run([exited(768)])

      assert {:error, {:command_failed, "exit status 3"}} = Claude.send_message("123456", "hi")
    end

    test "names the signal when the tool was killed rather than exited" do
      # 9 is what a wait status carries for SIGKILL, which is what a run that
      # was stopped from outside looks like.
      expect_run([exited(9)])

      assert {:error, {:command_failed, "killed by sigkill"}} =
               Claude.send_message("123456", "hi")
    end

    test "reports a run that ended some other way" do
      expect_run([fn os_pid -> {:DOWN, os_pid, :process, self(), :noproc} end])

      assert {:error, :noproc} = Claude.send_message("123456", "hi")
    end

    test "stops a tool that outlives its deadline, rather than waiting on it" do
      Application.put_env(:chat_agent, Claude, executable: "sh", timeout: 50)
      test_process = self()

      # Never says anything, and never finishes.
      expect(CommanderMock, :run, fn _command, _options -> {:ok, self(), 4242} end)

      expect(CommanderMock, :stop, fn os_pid ->
        send(test_process, {:stopped, os_pid})
        :ok
      end)

      assert {:error, :timeout} = Claude.send_message("123456", "hello")

      # Stopped rather than left running: nothing else would have.
      assert_receive {:stopped, 4242}
    end

    test "grants only what is configured, and nothing by default" do
      expect_run([finished()])

      assert {:ok, ""} = Claude.send_message("123456", "hello")

      assert_receive {:ran, command, _options}
      # Nothing configured, so nothing is granted: the tool refuses what it has
      # no permission for rather than asking somebody who is not there.
      refute Enum.any?(command, &String.starts_with?(&1, "--"))
    end

    test "passes the permissions it was given, with the prompt last" do
      Application.put_env(:chat_agent, Claude,
        executable: "sh",
        allowed_tools: ["Read", "Bash(git status)", "Bash(gh pr create:*)"],
        disallowed_tools: ["Bash(rm:*)"],
        permission_mode: "acceptEdits",
        add_dirs: ["/srv/checkouts/one"],
        model: "claude-sonnet-5",
        extra_args: ["--strict-mcp-config"]
      )

      expect_run([finished()])

      assert {:ok, ""} = Claude.send_message("123456", "what changed?")

      assert_receive {:ran, command, _options}

      assert ["--model", "claude-sonnet-5", "--permission-mode", "acceptEdits"] ==
               Enum.slice(command, 1..4)

      assert ["--allowedTools", "Read", "Bash(git status)", "Bash(gh pr create:*)"] ==
               Enum.slice(command, 5..8)

      assert ["--disallowedTools", "Bash(rm:*)"] == Enum.slice(command, 9..10)
      assert ["--add-dir", "/srv/checkouts/one"] == Enum.slice(command, 11..12)
      assert "--strict-mcp-config" in command

      # Last, always: a flag that takes a list would otherwise swallow it.
      assert Enum.take(command, -2) == ["-p", "what changed?"]
    end

    test "leaves out a permission list that was configured empty" do
      Application.put_env(:chat_agent, Claude,
        executable: "sh",
        allowed_tools: [],
        disallowed_tools: [],
        add_dirs: [],
        setting_sources: []
      )

      expect_run([finished()])

      assert {:ok, ""} = Claude.send_message("123456", "hello")

      assert_receive {:ran, command, _options}
      # An empty list is not an empty flag: passing one would be a flag with no
      # values for the tool to read.
      refute "--allowedTools" in command
      refute "--disallowedTools" in command
      refute "--add-dir" in command
      refute "--setting-sources" in command
    end

    test "points the tool at a policy file, and at the sources it may read" do
      Application.put_env(:chat_agent, Claude,
        executable: "sh",
        settings: "/etc/chat_agent/claude-settings.json",
        setting_sources: ["user", "project"]
      )

      expect_run([finished()])

      assert {:ok, ""} = Claude.send_message("123456", "hello")

      assert_receive {:ran, command, _options}
      assert ["--settings", "/etc/chat_agent/claude-settings.json"] == Enum.slice(command, 1..2)
      # One comma separated value, which is the shape this flag takes.
      assert ["--setting-sources", "user,project"] == Enum.slice(command, 3..4)
    end

    test "works where the session said, which it resolved before calling" do
      Application.put_env(:chat_agent, Claude, executable: "sh")

      expect_run([finished()])

      assert {:ok, ""} =
               Claude.send_message("123456", "hello", working_dir: "/srv/checkouts/my-app-folder")

      assert_receive {:ran, _command, options}
      assert {:cd, "/srv/checkouts/my-app-folder"} in options
    end

    test "runs where the application does when the session named nowhere" do
      Application.put_env(:chat_agent, Claude, executable: "sh")

      expect_run([finished()])

      assert {:ok, ""} = Claude.send_message("123456", "hello")

      assert_receive {:ran, _command, options}
      # Where to work is the session's to decide, and it decided nothing: this
      # module no longer keeps a directory of its own to fall back to.
      refute Enum.any?(options, &match?({:cd, _path}, &1))
    end

    test "passes anything else it is told straight back" do
      expect(CommanderMock, :run, fn _command, _options -> {:error, :enoent} end)

      assert {:error, :enoent} = Claude.send_message("123456", "hi")
    end

    test "reports an answer it does not recognise as a failure" do
      expect(CommanderMock, :run, fn _command, _options -> :something_else end)

      assert {:error, :something_else} = Claude.send_message("123456", "hi")
    end
  end
end
