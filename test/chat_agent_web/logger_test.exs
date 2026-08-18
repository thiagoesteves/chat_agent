defmodule ChatAgentWeb.LoggerTest do
  # Not async: :healthcheck_logging and the Logger level are global.
  use ChatAgentWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias ChatAgentWeb.Logger, as: RouteLogger

  setup do
    previous = Application.get_env(:chat_agent, :healthcheck_logging)

    on_exit(fn -> Application.put_env(:chat_agent, :healthcheck_logging, previous) end)
  end

  describe "log/1" do
    test "says nothing for the health route by default" do
      Application.put_env(:chat_agent, :healthcheck_logging, false)

      assert RouteLogger.log(%Plug.Conn{path_info: ["health"]}) == false
    end

    test "logs the health route once healthcheck logging is switched on" do
      Application.put_env(:chat_agent, :healthcheck_logging, true)

      assert RouteLogger.log(%Plug.Conn{path_info: ["health"]}) == :info
    end

    test "logs every other route regardless" do
      Application.put_env(:chat_agent, :healthcheck_logging, false)

      assert RouteLogger.log(%Plug.Conn{path_info: ["telegram", "webhook"]}) == :info
      assert RouteLogger.log(%Plug.Conn{path_info: ["channels"]}) == :info
    end
  end

  # The unit tests above prove the decision, these prove the endpoint asks for
  # it: a `log:` option dropped from Plug.Telemetry would pass the tests above.
  describe "endpoint wiring" do
    setup do
      previous_level = Logger.level()
      Logger.configure(level: :info)

      on_exit(fn -> Logger.configure(level: previous_level) end)
    end

    test "a health request writes nothing to the log by default", %{conn: conn} do
      Application.put_env(:chat_agent, :healthcheck_logging, false)

      logged = capture_log(fn -> get(conn, ~p"/health") end)

      refute logged =~ "/health"
    end

    test "a health request is logged once healthcheck logging is switched on", %{conn: conn} do
      Application.put_env(:chat_agent, :healthcheck_logging, true)

      logged = capture_log(fn -> get(conn, ~p"/health") end)

      assert logged =~ "GET /health"
    end

    test "an ordinary request is logged either way", %{conn: conn} do
      Application.put_env(:chat_agent, :healthcheck_logging, false)

      logged = capture_log(fn -> get(conn, ~p"/channels") end)

      assert logged =~ "GET /channels"
    end
  end
end
