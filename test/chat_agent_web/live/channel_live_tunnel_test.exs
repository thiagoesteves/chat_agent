defmodule ChatAgentWeb.ChannelLiveTunnelTest do
  # Not async: every test here configures the tunnel, which is global.
  use ChatAgentWeb.ConnCase, async: false

  setup :register_and_log_in_user

  alias ChatAgent.Channel.Health
  alias ChatAgent.Tunnel
  alias ChatAgent.Tunnel.Status

  setup do
    configured = Application.get_env(:chat_agent, Tunnel)
    on_exit(fn -> Application.put_env(:chat_agent, Tunnel, configured) end)

    :ok
  end

  defp configure(options), do: Application.put_env(:chat_agent, Tunnel, options)

  defp broadcast_health(health, webhooks \\ %{}) do
    Tunnel.broadcast(%Status{
      state: :connected,
      url: "https://a1b2c3.ngrok-free.app",
      provider: ChatAgent.Tunnel.Provider.Ngrok,
      webhooks: webhooks,
      health: health,
      since: DateTime.utc_now()
    })
  end

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

    test "says a service is delivering, once one has been asked", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/channels")

      broadcast_health(%{
        telegram:
          {:ok,
           %Health{
             state: :ok,
             url: "https://a1b2c3.ngrok-free.app/telegram/webhook",
             pending: 0,
             checked_at: ~U[2026-08-24 09:24:00Z]
           }}
      })

      html = render(view)
      assert html =~ "Delivering"
      assert html =~ "delivery checked 09:24"
      refute html =~ "Not delivering"
    end

    test "reads as connected until something says otherwise", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/channels")

      # A tunnel that is up, and a service that cannot reach it. The strip is
      # collapsed by default, so this has to be legible without opening it.
      broadcast_health(%{
        telegram:
          {:ok,
           %Health{
             state: :failing,
             url: "https://a1b2c3.ngrok-free.app/telegram/webhook",
             pending: 3,
             last_error: "Connection timed out",
             last_error_at: DateTime.add(DateTime.utc_now(), -26, :second),
             checked_at: DateTime.utc_now()
           }}
      })

      html = render(view)

      assert html =~ "is-degraded"
      assert html =~ "Not delivering"
      # The queue, and how long ago the delivery behind it failed: what makes
      # it worth acting on is that it is happening now.
      assert html =~ "3 queued"
      assert html =~ "Connection timed out 26s ago"
    end

    test "shows a queue behind a service that is still delivering", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/channels")

      broadcast_health(%{
        telegram:
          {:ok,
           %Health{
             state: :ok,
             url: "https://a1b2c3.ngrok-free.app/telegram/webhook",
             pending: 1,
             checked_at: DateTime.utc_now()
           }}
      })

      html = render(view)
      assert html =~ "Delivering · 1 queued"
      refute html =~ "is-degraded"
    end

    test "says a service is not delivering even when it will not say why", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/channels")

      # A service that reports a queue it cannot clear and nothing about the
      # attempts: there is still something to say, and it is the queue.
      broadcast_health(%{
        telegram:
          {:ok,
           %Health{
             state: :failing,
             url: "https://a1b2c3.ngrok-free.app/telegram/webhook",
             pending: 7,
             checked_at: DateTime.utc_now()
           }}
      })

      html = render(view)
      assert html =~ "Not delivering · 7 queued"
      assert html =~ "is-degraded"
    end

    test "says what went wrong even when the service did not say when", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/channels")

      broadcast_health(%{
        telegram:
          {:ok,
           %Health{
             state: :failing,
             url: "https://a1b2c3.ngrok-free.app/telegram/webhook",
             pending: 2,
             last_error: "Connection timed out",
             checked_at: DateTime.utc_now()
           }}
      })

      html = render(view)
      assert html =~ "Not delivering · 2 queued · Connection timed out"
      # No age, rather than an age of nothing.
      refute html =~ "ago"
    end

    test "reads a failure in minutes and hours once it is no longer seconds", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/channels")

      for {age, reads} <- [{-90, "1m ago"}, {-7200, "2h ago"}] do
        broadcast_health(%{
          telegram:
            {:ok,
             %Health{
               state: :failing,
               url: "https://a1b2c3.ngrok-free.app/telegram/webhook",
               pending: 2,
               last_error: "Connection timed out",
               last_error_at: DateTime.add(DateTime.utc_now(), age, :second),
               checked_at: DateTime.utc_now()
             }}
        })

        assert render(view) =~ "Connection timed out #{reads}"
      end
    end

    test "keeps reporting the registration where a service cannot be asked", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/channels")

      broadcast_health(
        %{whatsapp: {:error, :not_supported}, telegram: {:error, :timeout}},
        %{whatsapp: {:error, :not_supported}, telegram: {:ok, :registered}}
      )

      html = render(view)
      # A service that has no answer to give still says where it was set.
      assert html =~ "Set outside this app"
      # One that has an answer and could not be reached says so, rather than
      # reading as a delivery failure.
      assert html =~ "Could not be checked"
      refute html =~ "is-degraded"
    end

    test "says when nothing more will be done about a failure", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/channels")

      Tunnel.broadcast(%Status{
        state: :connected,
        url: "https://a1b2c3.ngrok-free.app",
        provider: ChatAgent.Tunnel.Provider.Ngrok,
        error: :delivery_failing,
        since: DateTime.utc_now()
      })

      assert render(view) =~ "after being told again and given a new URL"
    end

    test "asks for a check on request, rather than waiting for the interval", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/channels")

      Tunnel.broadcast(%Status{
        state: :connected,
        url: "https://a1b2c3.ngrok-free.app",
        provider: ChatAgent.Tunnel.Provider.Ngrok,
        since: DateTime.utc_now()
      })

      # No tunnel server is running in the test environment, so what is under
      # test here is that the button asks: the answer arrives on the topic.
      assert view |> element("button", "Check now") |> render_click()
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
      # The whole URL, token and all. The dashboard is behind a login and the
      # point of the button is pasting this into the service that has to call
      # it, so a redacted URL would be one that does not work.
      assert html =~
               ~s(data-copy="https://a1b2c3.ngrok-free.app/telegram/webhook?token=test_telegram_webhook_token")

      assert html =~ ~s(aria-label="Copy the public URL")
    end
  end
end
