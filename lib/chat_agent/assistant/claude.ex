defmodule ChatAgent.Assistant.Claude do
  @moduledoc """
  Assistant backed by the `claude` command line tool.

  Runs the executable through `ChatAgent.Commander.Runner`, which gives the run
  a process of its own and answers with what it said, and which reaches the
  operating system through `ChatAgent.Commander`, so a test swaps the whole
  thing for a mock and no test ever runs the real one.

  Where it runs is the session's to decide and arrives with each call, since a
  conversation may say where it wants work done. See
  `ChatAgent.Assistant.working_dir/1`.

  The command is an argument list rather than a command line, which means no
  shell is involved: a prompt arrives from whoever is talking to the bot, and a
  shell would read the punctuation in it as syntax.

  ## Configuration

      config :chat_agent, ChatAgent.Assistant.Claude,
        # The executable to run. Looked up on the PATH, or given as a path.
        executable: "claude",
        # How long one reply may take before the run is abandoned.
        timeout: :timer.minutes(2),
        # What it may do. Each entry is one value of --allowedTools, and
        # without any, a tool that needs permission is refused rather than
        # asked about, since nobody is at a terminal to answer.
        allowed_tools: [],
        # What it may not do, whatever else allows it.
        disallowed_tools: [],
        # One of the modes the tool itself defines, such as "acceptEdits".
        permission_mode: nil,
        # A settings file of its own, which is where a policy longer than a
        # list belongs: allow and deny rules, kept and reviewed as a file.
        settings: nil,
        # Which of the tool's own settings sources to load, such as
        # ["project"] to honour a repository's .claude/settings.json.
        setting_sources: [],
        # Directories it may reach outside the one it runs in.
        add_dirs: [],
        model: nil,
        # Anything else to pass, one argument per element.
        extra_args: []

  ## What it is allowed to do

  Permissions are the whole security question here, because the prompt comes
  from whoever authenticated with the bot. Granting `"Bash(gh:*)"` grants it to
  every conversation that knows the password, and what the tool does it does as
  whoever is running this app.

  Nothing is granted by default: the list starts empty, and in this mode the
  tool refuses what it has no permission for rather than asking, since nobody
  is at a terminal to answer. Grant the narrowest thing that does the job:

      allowed_tools: ["Read", "Grep", "Bash(git status *)"]

  A policy longer than a list belongs in a settings file of its own, which can
  say what is refused as well as what is allowed, and can be read and reviewed
  as a file:

      settings: "/etc/chat_agent/claude-settings.json"

  A repository's own `.claude/settings.json` is only read when it is asked for,
  which is what `setting_sources: ["project"]` does.
  """

  @behaviour ChatAgent.Assistant.Adapter

  alias ChatAgent.Commander.Runner

  require Logger

  @default_executable "claude"
  @default_timeout :timer.minutes(2)

  ### ==========================================================================
  ### Callback functions
  ### ==========================================================================

  @impl true
  def send_message(_conversation, prompt, options \\ []) do
    case executable() do
      {:ok, executable} -> run(executable, prompt, options)
      {:error, reason} -> {:error, reason}
    end
  end

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================

  # Found once, before running anything, so a missing tool is reported as
  # exactly that. Left to the run, it arrives as an exit status wrapped around
  # a sentence from a shell, which reads like the tool refused rather than like
  # it was never there.
  defp executable do
    configured = config(:executable) || @default_executable

    case System.find_executable(configured) do
      nil -> {:error, {:executable_not_found, configured}}
      path -> {:ok, path}
    end
  end

  # `-p` prints one reply and exits, rather than opening a session.
  #
  # Run through `ChatAgent.Commander.Runner`, which gives the run a process of
  # its own and holds the deadline there: erlexec's own timeout bounds starting
  # a process, not running one, so a tool that hangs would otherwise be waited
  # on for as long as it hangs. Waiting for it here would mean waiting for the
  # run's messages in the session's mailbox, which is not this module's to
  # occupy.
  defp run(executable, prompt, options) do
    Logger.info(%{what: "claude_request", prompt_length: String.length(prompt)})

    command = [executable] ++ arguments() ++ ["-p", prompt]
    run_options = [{:timeout, timeout()} | working_dir(options)]

    case Runner.run(command, run_options) do
      {:ok, output} ->
        {:ok, said(output)}

      {:error, {:exit_status, status, output}} ->
        {:error, {:command_failed, failure(output, status)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The prompt goes last, after every flag: a flag that takes a list of values
  # would otherwise read the prompt as one of them.
  defp arguments do
    List.flatten([
      flag("--model", config(:model)),
      flag("--permission-mode", config(:permission_mode)),
      flag("--settings", config(:settings)),
      flag("--setting-sources", sources(config(:setting_sources))),
      flag("--allowedTools", config(:allowed_tools)),
      flag("--disallowedTools", config(:disallowed_tools)),
      flag("--add-dir", config(:add_dirs)),
      config(:extra_args) || []
    ])
  end

  # One comma separated value rather than a list of them, which is the shape
  # this particular flag takes.
  defp sources(nil), do: nil
  defp sources([]), do: nil
  defp sources(sources), do: Enum.join(sources, ",")

  defp flag(_name, nil), do: []
  defp flag(_name, []), do: []
  defp flag(name, values) when is_list(values), do: [name | Enum.map(values, &to_string/1)]
  defp flag(name, value), do: [name, to_string(value)]

  # Where it runs, which for a tool that reads and writes files is most of what
  # it can reach. Decided by the session rather than here: one place resolves a
  # directory, against the one root a conversation may pick from, and hands the
  # answer down.
  defp working_dir(options) do
    case Keyword.get(options, :working_dir) do
      nil -> []
      path -> [{:cd, path}]
    end
  end

  # What the tool printed, without the newline it ends its reply with: this is
  # going into a chat message rather than onto a terminal.
  defp said(output), do: String.trim(output)

  # What the tool said, if it said anything, and otherwise how it ended.
  defp failure(output, status) do
    case said(output) do
      "" -> ended(status)
      said -> said
    end
  end

  defp ended(status) do
    case :exec.status(status) do
      {:status, code} -> "exit status #{code}"
      {:signal, signal, _core} -> "killed by #{signal}"
    end
  end

  defp timeout, do: config(:timeout) || @default_timeout

  defp config(key), do: Application.get_env(:chat_agent, __MODULE__, [])[key]
end
