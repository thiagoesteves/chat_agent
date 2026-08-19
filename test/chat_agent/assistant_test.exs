defmodule ChatAgent.AssistantTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  alias ChatAgent.Assistant
  alias ChatAgent.Channel.Message

  doctest ChatAgent.Assistant, import: true

  setup :verify_on_exit!

  setup do
    configured = Application.get_env(:chat_agent, Assistant)
    on_exit(fn -> Application.put_env(:chat_agent, Assistant, configured) end)

    :ok
  end

  defp configure(options) do
    Application.put_env(
      :chat_agent,
      Assistant,
      Keyword.merge(Application.get_env(:chat_agent, Assistant, []), options)
    )
  end

  describe "send_message/3" do
    test "hands the prompt to the configured assistant" do
      expect(ChatAgent.AssistantMock, :send_message, fn conversation, prompt, options ->
        assert conversation == "123456"
        assert prompt == "User: hello"
        assert options == [working_dir: "/srv/checkouts/one"]
        {:ok, "hi"}
      end)

      assert {:ok, "hi"} =
               Assistant.send_message(:claude, "123456", "User: hello",
                 working_dir: "/srv/checkouts/one"
               )
    end

    test "returns the assistant's result unchanged" do
      expect(ChatAgent.AssistantMock, :send_message, fn _conversation, _prompt, _options ->
        {:error, {:executable_not_found, "claude"}}
      end)

      assert {:error, {:executable_not_found, "claude"}} =
               Assistant.send_message(:claude, "123456", "hello")
    end

    test "reports an assistant that is not configured" do
      assert {:error, {:unknown_assistant, :nobody}} =
               Assistant.send_message(:nobody, "123456", "hello")
    end
  end

  describe "authentication/1" do
    test "reads a password typed without quotes, which is what people type" do
      assert {:ok, %{password: "hunter2", assistant: nil, work_dir: nil}} =
               Assistant.authentication("/auth hunter2")

      assert {:ok, %{password: "hunter2", assistant: "claude"}} =
               Assistant.authentication("/auth-claude hunter2")
    end

    test "reads a quoted password, which is how one with a space is given" do
      assert {:ok, %{password: "hunter2"}} = Assistant.authentication(~s(/auth "hunter2"))

      assert {:ok, %{password: "a long one, with commas"}} =
               Assistant.authentication(~s(/auth "a long one, with commas"))

      assert {:ok, %{password: "two words", assistant: "claude"}} =
               Assistant.authentication(~s(/auth-claude "two words"))
    end

    test "reads the working directory a conversation asked for" do
      assert {:ok, %{password: "hunter2", work_dir: "my-app-folder"}} =
               Assistant.authentication("/auth hunter2 --work-dir my-app-folder")

      assert {:ok,
              %{password: "two words", assistant: "claude", work_dir: "nested/my-app-folder"}} =
               Assistant.authentication(
                 ~s(/auth-claude "two words" --work-dir nested/my-app-folder)
               )
    end

    test "ignores what a chat client adds around it" do
      assert {:ok, %{password: "hunter2"}} = Assistant.authentication("  /auth hunter2  ")
      assert {:ok, %{password: "hunter2"}} = Assistant.authentication("/auth hunter2\n")
    end

    test "refuses anything that is not an attempt" do
      assert :error = Assistant.authentication("hello there")
      assert :error = Assistant.authentication("/auth")
      assert :error = Assistant.authentication("/authorise something")
      assert :error = Assistant.authentication(~s(please /auth "hunter2"))
      # A password is one word or one quoted string, so a sentence after it is
      # not an attempt with a long password.
      assert :error = Assistant.authentication("/auth hunter2 and then some")
    end
  end

  describe "working_dir/1" do
    setup do
      root = Path.join(System.tmp_dir!(), "assistant_root_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "my-app-folder"))
      File.mkdir_p!(Path.join(root, "nested/chat_agent"))
      on_exit(fn -> File.rm_rf!(root) end)

      configure(working_dir_root: root)

      %{root: root}
    end

    test "resolves a name inside the one root on offer", %{root: root} do
      assert {:ok, resolved} = Assistant.working_dir("my-app-folder")
      assert resolved == Path.join(root, "my-app-folder")

      assert {:ok, nested} = Assistant.working_dir("nested/chat_agent")
      assert nested == Path.join(root, "nested/chat_agent")
    end

    test "refuses a path that climbs out of it" do
      # Whoever knows the password picks this, so where it lands is the whole
      # question, however it is spelled.
      assert {:error, :not_found} = Assistant.working_dir("../..")
      assert {:error, :not_found} = Assistant.working_dir("my-app-folder/../../..")
      assert {:error, :not_found} = Assistant.working_dir("/etc")
      assert {:error, :not_found} = Assistant.working_dir("~")
    end

    test "refuses a directory that is not there" do
      assert {:error, :not_found} = Assistant.working_dir("no-such-repository")
    end

    test "offers nothing when no root is configured" do
      configure(working_dir_root: nil)

      assert {:error, :not_offered} = Assistant.working_dir("my-app-folder")
    end
  end

  describe "default_working_dir/0" do
    setup do
      root = Path.join(System.tmp_dir!(), "assistant_root_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "my-app-folder"))
      on_exit(fn -> File.rm_rf!(root) end)

      %{root: root}
    end

    test "reads the default as a name under the same root", %{root: root} do
      configure(working_dir_root: root, working_dir: "my-app-folder")

      # Written the way a conversation writes it, so one root governs both and
      # neither has to repeat the other.
      assert Assistant.default_working_dir() == Path.join(root, "my-app-folder")
    end

    test "takes an absolute path only where there is no root to pick from", %{root: root} do
      configure(working_dir_root: nil, working_dir: Path.join(root, "my-app-folder"))

      assert Assistant.default_working_dir() == Path.join(root, "my-app-folder")
    end

    test "answers nothing, loudly, when the default is not usable", %{root: root} do
      configure(working_dir_root: root, working_dir: "no-such-repository")

      log = capture_log(fn -> assert Assistant.default_working_dir() == nil end)

      assert log =~ "assistant_working_dir_unusable"
    end

    test "answers nothing when none is configured" do
      configure(working_dir_root: nil, working_dir: nil)

      assert Assistant.default_working_dir() == nil
    end
  end

  describe "redact/1" do
    test "replaces the password in a message, leaving the rest alone" do
      message = Message.new(sender: "123456", conversation: "123456", text: ~s(/auth "hunter2"))

      assert %Message{text: ~s(/auth "*****")} = Assistant.redact(message)
    end

    test "replaces one typed without quotes, which is the form people use" do
      message = Message.new(sender: "123456", conversation: "123456", text: "/auth hunter2")

      # Whatever opens a session is hidden. A form one of them knew and the
      # other did not would be a password left on the dashboard.
      assert %Message{text: "/auth *****"} = Assistant.redact(message)
    end

    test "keeps the assistant a message named" do
      message =
        Message.new(sender: "123456", conversation: "123456", text: ~s(/auth-claude "hunter2"))

      assert %Message{text: ~s(/auth-claude "*****")} = Assistant.redact(message)
    end

    test "leaves a message carrying no password untouched" do
      message = Message.new(sender: "123456", conversation: "123456", text: "what is OTP?")

      assert %Message{text: "what is OTP?"} = Assistant.redact(message)
    end
  end

  describe "subscribe/0" do
    test "receives session news until unsubscribed" do
      assert :ok = Assistant.subscribe()

      session = %{key: {:mock, "123456"}, assistant: :claude, id: "a1b2c3", pid: self()}
      Assistant.broadcast({:session_opened, session})

      assert_receive {:assistant, {:session_opened, ^session}}

      assert :ok = Assistant.unsubscribe()
      Assistant.broadcast({:session_closed, session.key})

      refute_receive {:assistant, _event}
    end
  end

  describe "sessions/0" do
    test "answers nothing when no router is running" do
      # The application starts none in the test environment, so this is the
      # honest answer rather than a crash in whatever asked.
      assert Assistant.sessions() == %{}
    end
  end

  describe "configuration" do
    test "answers with what is configured" do
      configure(default: :claude, session_timeout: 1_000, history_limit: 7, password: "secret")

      assert Assistant.default() == :claude
      assert Assistant.session_timeout() == 1_000
      assert Assistant.history_limit() == 7
      assert Assistant.password() == "secret"
      assert Assistant.list() == [claude: ChatAgent.AssistantMock]
    end

    test "falls back to its own defaults" do
      Application.put_env(:chat_agent, Assistant, [])

      assert Assistant.default() == :claude
      assert Assistant.session_timeout() == :timer.minutes(5)
      assert Assistant.history_limit() == 20
      assert Assistant.password() == nil
      assert Assistant.list() == []
    end

    test "is enabled only with both a password and an assistant to answer" do
      configure(password: "secret")
      assert Assistant.enabled?()

      configure(password: nil)
      refute Assistant.enabled?()

      Application.put_env(:chat_agent, Assistant, password: "secret", adapters: [])
      refute Assistant.enabled?()
    end
  end
end
