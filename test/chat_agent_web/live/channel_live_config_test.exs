defmodule ChatAgentWeb.ChannelLiveConfigTest do
  # Not async: registering an extra channel changes global application config.
  use ChatAgentWeb.ConnCase, async: false

  import Mox

  test "renders a channel it has no brand icon for", %{conn: conn} do
    configured = Application.get_env(:chat_agent, ChatAgent.Channel)

    on_exit(fn -> Application.put_env(:chat_agent, ChatAgent.Channel, configured) end)

    Application.put_env(:chat_agent, ChatAgent.Channel,
      adapters: Keyword.put(configured[:adapters], :carrier_pigeon, ChatAgent.ChannelMock)
    )

    stub(ChatAgent.ChannelMock, :reference, fn ->
      %{url: "https://example.com/api", fields: [{"pigeon.id", "Which pigeon carried it."}]}
    end)

    {:ok, view, html} = live(conn, ~p"/channels")

    # The channel list is driven by config, so a new channel appears with no
    # change to the view, falling back to the generic icon.
    assert html =~ "carrier_pigeon"
    assert has_element?(view, ".channel-avatar.is-carrier_pigeon svg")
    assert has_element?(view, "section.channel-card", "carrier_pigeon")
  end
end
