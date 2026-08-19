defmodule ChatAgentWeb.ChannelLiveConfigTest do
  # Not async: registering an extra channel changes global application config.
  use ChatAgentWeb.ConnCase, async: false

  import Mox

  alias ChatAgent.Channel
  alias ChatAgent.Channel.Message
  alias ChatAgent.ChannelMock

  test "renders a channel it has no brand icon for", %{conn: conn} do
    configured = Application.get_env(:chat_agent, Channel)

    on_exit(fn -> Application.put_env(:chat_agent, Channel, configured) end)

    Application.put_env(:chat_agent, Channel,
      adapters: Keyword.put(configured[:adapters], :carrier_pigeon, ChannelMock)
    )

    stub(ChannelMock, :reference, fn ->
      %{url: "https://example.com/api", fields: [{"pigeon.id", "Which pigeon carried it."}]}
    end)

    {:ok, view, html} = live(conn, ~p"/channels")

    # The channel list is driven by config, so a new channel appears with no
    # change to the view, falling back to the generic icon.
    assert html =~ "carrier_pigeon"
    assert has_element?(view, ".channel-avatar.is-carrier_pigeon svg")
    assert has_element?(view, "section.channel-card", "carrier_pigeon")
  end

  test "names the conversation generically when no identifier carries its value", %{conn: conn} do
    stub(ChannelMock, :reference, fn ->
      %{url: "https://example.com/api", fields: [{"pigeon.id", "Which pigeon carried it."}]}
    end)

    stub(ChannelMock, :handle_message, fn _payload ->
      # The reply address is not among the identifiers, so the composer has no
      # channel vocabulary to name it with.
      {:ok,
       Message.new(
         sender: "loft-7",
         conversation: "loft-7",
         identifiers: [{"pigeon.id", "p-1"}],
         text: "Coo"
       )}
    end)

    register_mock_channel()

    {:ok, view, _html} = live(conn, ~p"/channels")

    :ok = Channel.handle_message(:carrier_pigeon, %{"any" => "payload"})

    card = view |> element("section.channel-card", "carrier_pigeon") |> render()

    assert card =~ "Replying to"
    assert card =~ "conversation"
    assert card =~ "loft-7"
  end

  defp register_mock_channel do
    configured = Application.get_env(:chat_agent, Channel)

    on_exit(fn -> Application.put_env(:chat_agent, Channel, configured) end)

    Application.put_env(:chat_agent, Channel,
      adapters: Keyword.put(configured[:adapters], :carrier_pigeon, ChannelMock)
    )
  end
end
