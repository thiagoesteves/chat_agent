defmodule ChatAgentWeb.ChannelLiveTunnelTest do
  # Not async: every test here configures the tunnel, which is global.
  use ChatAgentWeb.ConnCase, async: false

  setup :register_and_log_in_user

  alias ChatAgent.Tunnel
  alias ChatAgent.Tunnel.Status

  setup do
    configured = Application.get_env(:chat_agent, Tunnel)
    on_exit(fn -> Application.put_env(:chat_agent, Tunnel, configured) end)

    :ok
  end

  defp configure(options), do: Application.put_env(:chat_agent, Tunnel, options)

  describe "with no tunnel run" do
    test "reports nothing about a tunnel, and lists the callbacks", %{conn: conn} do
      configure(url: "https://chat.example.com")

      {:ok, _view, html} = live(conn, ~p"/channels")

      # Nothing about a tunnel: no state, no provider, no agent.
      refute html =~ "tunnel-state"
      refute html =~ "callback-state"
      assert html =~ "Callbacks"
      assert html =~ "https://chat.example.com/telegram/webhook"
      assert html =~ "https://chat.example.com/whatsapp/webhook"
    end

    test "shows the route each webhook is served on when no URL is configured", %{conn: conn} do
      configure([])

      {:ok, _view, html} = live(conn, ~p"/channels")

      assert html =~ "Callbacks"
      assert html =~ "/telegram/webhook"
      assert html =~ "no public URL configured"
    end
  end

  describe "with a tunnel" do
    setup do
      configure(provider: ChatAgent.Tunnel.Provider.Ngrok)

      :ok
    end

    test "reports a tunnel that is configured but not running", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/channels")

      assert html =~ "Not running"
      assert html =~ "waiting for the tunnel"
    end

    test "follows the tunnel as it connects, and says what was registered", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/channels")

      Tunnel.broadcast(%Status{
        state: :connecting,
        provider: ChatAgent.Tunnel.Provider.Ngrok,
        since: DateTime.utc_now()
      })

      html = render(view)
      assert html =~ "Starting agent"
      assert html =~ "waiting for the tunnel"

      Tunnel.broadcast(%Status{
        state: :connected,
        url: "https://a1b2c3.ngrok-free.app",
        provider: ChatAgent.Tunnel.Provider.Ngrok,
        webhooks: %{telegram: {:ok, :registered}, whatsapp: {:error, :not_supported}},
        since: DateTime.utc_now()
      })

      html = render(view)
      assert html =~ "Connected"
      assert html =~ "ngrok"
      assert html =~ "https://a1b2c3.ngrok-free.app/telegram/webhook"
      assert html =~ "Registered"
      # WhatsApp cannot be registered from here, and says so rather than
      # looking like a failure.
      assert html =~ "Set outside this app"
    end

    test "names every state the machine can be in", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/channels")

      for {state, label} <- [
            {:authenticating, "Authenticating"},
            {:connecting, "Starting agent"},
            {:registering, "Registering"},
            {:connected, "Connected"}
          ] do
        Tunnel.broadcast(%Status{state: state, provider: ChatAgent.Tunnel.Provider.Ngrok})

        assert render(view) =~ label
      end
    end

    test "distinguishes a webhook it wrote from one that already pointed here", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/channels")

      Tunnel.broadcast(%Status{
        state: :connected,
        url: "https://a1b2c3.ngrok-free.app",
        provider: ChatAgent.Tunnel.Provider.Ngrok,
        webhooks: %{telegram: {:ok, :unchanged}},
        since: DateTime.utc_now()
      })

      # Restarting the app is not a write to someone else's API, and the page
      # says which of the two happened.
      assert render(view) =~ "Already pointed here"
    end

    test "names a registration that failed, and the error behind it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/channels")

      Tunnel.broadcast(%Status{
        state: :registering,
        url: "https://a1b2c3.ngrok-free.app",
        provider: ChatAgent.Tunnel.Provider.Ngrok,
        webhooks: %{telegram: {:error, :timeout}},
        error: {:agent_exited, :normal},
        since: DateTime.utc_now()
      })

      html = render(view)
      assert html =~ "Registration failed"
      # The error is a sentence rather than a tuple.
      assert html =~ "The agent stopped"
    end

    test "words the errors somebody can act on", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/channels")

      for {error, sentence} <- [
            {{:executable_not_found, "ngrok"}, "ngrok was not found on the PATH"},
            {:connect_timeout, "did not report a URL in time"},
            {:registration_failed, "could not be told where to call"},
            {{:something_new, 42}, "Last error:"}
          ] do
        Tunnel.broadcast(%Status{
          state: :authenticating,
          provider: ChatAgent.Tunnel.Provider.Ngrok,
          error: error
        })

        assert render(view) =~ sentence
      end
    end

    test "offers each URL for copying, since they are pasted elsewhere", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/channels")

      Tunnel.broadcast(%Status{
        state: :connected,
        url: "https://a1b2c3.ngrok-free.app",
        provider: ChatAgent.Tunnel.Provider.Ngrok,
        since: DateTime.utc_now()
      })

      html = render(view)

      assert html =~ ~s(phx-hook="CopyToClipboard")
      assert html =~ ~s(data-copy="https://a1b2c3.ngrok-free.app/telegram/webhook")
      assert html =~ ~s(aria-label="Copy the public URL")
    end
  end
end
