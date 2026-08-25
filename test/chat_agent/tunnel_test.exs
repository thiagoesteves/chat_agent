defmodule ChatAgent.TunnelTest do
  use ExUnit.Case, async: false

  alias ChatAgent.Tunnel
  alias ChatAgent.Tunnel.Status

  setup do
    configured = Application.get_env(:chat_agent, Tunnel)
    on_exit(fn -> Application.put_env(:chat_agent, Tunnel, configured) end)

    :ok
  end

  defp configure(options), do: Application.put_env(:chat_agent, Tunnel, options)

  describe "url/0" do
    test "answers the statically configured URL" do
      configure(url: "https://chat.example.com")

      assert {:ok, "https://chat.example.com"} = Tunnel.url()
    end

    test "leaves no trailing slash behind, so a path can be appended to it" do
      configure(url: "https://chat.example.com/")

      assert {:ok, "https://chat.example.com"} = Tunnel.url()
    end

    test "prefers the static URL over a tunnel, which is how a deployment runs" do
      configure(url: "https://chat.example.com", provider: ChatAgent.TunnelProviderMock)

      assert {:ok, "https://chat.example.com"} = Tunnel.url()
    end

    test "does not need a tunnel once a public URL is configured" do
      configure(url: "https://chat.example.com", provider: ChatAgent.TunnelProviderMock)

      refute Tunnel.enabled?()
      assert %Status{state: :disabled, url: "https://chat.example.com"} = Tunnel.status()
    end

    test "reports that no URL is configured when there is neither" do
      configure([])

      assert {:error, :not_configured} = Tunnel.url()
    end

    test "reports a provider that is not connected" do
      configure(provider: ChatAgent.TunnelProviderMock)

      assert {:error, :not_connected} = Tunnel.url()
    end
  end

  describe "webhook_url/1" do
    test "builds a channel's webhook URL from the public one" do
      configure(url: "https://chat.example.com")

      assert {:ok, "https://chat.example.com/telegram/webhook?token=test_telegram_webhook_token"} =
               Tunnel.webhook_url(:telegram)
    end

    test "passes on the reason there is no URL" do
      configure([])

      assert {:error, :not_configured} = Tunnel.webhook_url(:telegram)
    end
  end

  describe "status/0" do
    test "reports a tunnel that is not run at all" do
      configure(url: "https://chat.example.com")

      assert %Status{state: :disabled, url: "https://chat.example.com"} = Tunnel.status()
    end

    test "reports a configured tunnel whose server is not running" do
      configure(provider: ChatAgent.TunnelProviderMock)

      assert %Status{state: :down, url: nil} = Tunnel.status()
    end
  end

  describe "enabled?/0" do
    test "is true only for a provider with no public URL already configured" do
      configure(provider: ChatAgent.TunnelProviderMock)
      assert Tunnel.enabled?()

      configure(provider: ChatAgent.TunnelProviderMock, url: "https://chat.example.com")
      refute Tunnel.enabled?()

      configure(url: "https://chat.example.com")
      refute Tunnel.enabled?()

      configure([])
      refute Tunnel.enabled?()
    end
  end

  describe "renew/0" do
    test "refuses where the URL is a static one, which no agent opened" do
      # A deployment behind DNS is reachable at the same place tomorrow, so
      # there is no agent to run again.
      configure(url: "https://chat.example.com")
      assert Tunnel.renew() == {:error, :not_configured}

      configure(provider: ChatAgent.TunnelProviderMock, url: "https://chat.example.com")
      assert Tunnel.renew() == {:error, :not_configured}

      configure([])
      assert Tunnel.renew() == {:error, :not_configured}
    end

    test "reports a tunnel that is configured but not running" do
      configure(provider: ChatAgent.TunnelProviderMock)

      assert Tunnel.renew() == {:error, :down}
    end
  end

  describe "connected?/0" do
    test "is true whenever a URL is available" do
      configure(url: "https://chat.example.com")
      assert Tunnel.connected?()

      configure([])
      refute Tunnel.connected?()
    end
  end

  describe "subscribe/0" do
    test "receives every broadcast state change until unsubscribed" do
      assert :ok = Tunnel.subscribe()

      status = %Status{state: :connected, url: "https://a1b2c3.ngrok-free.app"}
      Tunnel.broadcast(status)

      assert_receive {:tunnel, ^status}

      assert :ok = Tunnel.unsubscribe()
      Tunnel.broadcast(status)

      refute_receive {:tunnel, _status}
    end
  end

  describe "topic/0" do
    test "names one topic for the node's single tunnel" do
      assert Tunnel.topic() == "tunnel"
    end
  end
end
