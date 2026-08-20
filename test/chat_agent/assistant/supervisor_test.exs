defmodule ChatAgent.Assistant.SupervisorTest do
  use ExUnit.Case, async: false

  alias ChatAgent.Assistant

  setup do
    configured = Application.get_env(:chat_agent, Assistant)
    on_exit(fn -> Application.put_env(:chat_agent, Assistant, configured) end)

    Application.put_env(
      :chat_agent,
      Assistant,
      Keyword.put(configured, :salted_password, Pbkdf2.hash_pwd_salt("secret"))
    )

    :ok
  end

  test "starts the router and the supervisor its sessions run under" do
    # The application starts none of this without a password, which is why a
    # test can start it and know what it is looking at.
    pid = start_supervised!({Assistant.Supervisor, []})

    assert length(Supervisor.which_children(pid)) == 2
    assert Process.whereis(Assistant.Router)
    assert Process.whereis(Assistant.SessionSupervisor)
  end
end
