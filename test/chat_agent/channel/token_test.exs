defmodule ChatAgent.Channel.TokenTest do
  # Not async: every test here changes global application configuration.
  use ExUnit.Case, async: false

  alias ChatAgent.Channel.Token

  doctest ChatAgent.Channel.Token

  setup do
    configured = Application.get_env(:chat_agent, Token)
    tunnel = Application.get_env(:chat_agent, ChatAgent.Tunnel)

    on_exit(fn ->
      Application.put_env(:chat_agent, Token, configured)
      Application.put_env(:chat_agent, ChatAgent.Tunnel, tunnel)
    end)

    %{configured: configured}
  end

  describe "for/1" do
    test "answers the configured token" do
      assert Token.for_channel(:telegram) == "test_telegram_webhook_token"
    end

    test "answers the same token every time it is asked", %{configured: configured} do
      Application.put_env(:chat_agent, Token, Keyword.delete(configured, :telegram))
      :persistent_term.erase({Token, :telegram})

      assert Token.for_channel(:telegram) == Token.for_channel(:telegram)
    end

    test "generates a token for a channel that has none", %{configured: configured} do
      Application.put_env(:chat_agent, Token, Keyword.delete(configured, :telegram))
      :persistent_term.erase({Token, :telegram})

      token = Token.for_channel(:telegram)

      refute token == "test_telegram_webhook_token"
      # 32 bytes, url-safe and unpadded, which is 43 characters.
      assert String.length(token) == 43
      assert token =~ ~r/^[A-Za-z0-9_-]+$/
    end

    test "gives two channels different tokens, so one URL does not open another" do
      refute Token.for_channel(:telegram) == Token.for_channel(:whatsapp)
    end
  end

  describe "valid?/2" do
    test "accepts the channel's own token" do
      assert Token.valid?(:telegram, "test_telegram_webhook_token")
    end

    test "refuses another channel's token" do
      refute Token.valid?(:telegram, "test_whatsapp_webhook_token")
    end

    test "refuses a wrong token, an empty one, and none at all" do
      refute Token.valid?(:telegram, "wrong")
      refute Token.valid?(:telegram, "")
      refute Token.valid?(:telegram, nil)
    end

    test "refuses a token that is only a prefix of the right one" do
      refute Token.valid?(:telegram, "test_telegram_webhook_toke")
    end
  end

  describe "install/0" do
    test "leaves a configured token alone" do
      assert Token.install() == :ok
      assert Token.for_channel(:telegram) == "test_telegram_webhook_token"
    end

    test "settles a token for a channel that has none", %{configured: configured} do
      Application.put_env(:chat_agent, Token, Keyword.delete(configured, :telegram))
      :persistent_term.erase({Token, :telegram})

      assert Token.install() == :ok

      settled = :persistent_term.get({Token, :telegram})

      assert is_binary(settled)
      assert Token.for_channel(:telegram) == settled
    end

    test "warns when it generates one behind a URL nothing will re-register",
         %{configured: configured} do
      Application.put_env(:chat_agent, Token, Keyword.delete(configured, :telegram))
      :persistent_term.erase({Token, :telegram})

      tunnel = Application.get_env(:chat_agent, ChatAgent.Tunnel, [])

      Application.put_env(
        :chat_agent,
        ChatAgent.Tunnel,
        Keyword.put(tunnel, :url, "https://example.com")
      )

      logged = ExUnit.CaptureLog.capture_log(fn -> Token.install() end)

      assert logged =~ "webhook_token_generated"
      assert logged =~ "telegram"
      # The token itself is what the warning is about, never part of it.
      refute logged =~ :persistent_term.get({Token, :telegram})
    end

    test "says nothing when the URL is a tunnel's, since it re-registers anyway",
         %{configured: configured} do
      Application.put_env(:chat_agent, Token, Keyword.delete(configured, :telegram))
      :persistent_term.erase({Token, :telegram})

      tunnel = Application.get_env(:chat_agent, ChatAgent.Tunnel, [])
      Application.put_env(:chat_agent, ChatAgent.Tunnel, Keyword.put(tunnel, :url, nil))

      logged = ExUnit.CaptureLog.capture_log(fn -> Token.install() end)

      refute logged =~ "webhook_token_generated"
    end
  end
end
