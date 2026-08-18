defmodule ChatAgentWeb.CoreComponentsTest do
  use ChatAgentWeb.ConnCase, async: true

  import ChatAgentWeb.CoreComponents

  describe "flash/1" do
    test "hands the notice to the hook that dismisses it, tagged with its kind" do
      html = render_component(&flash/1, kind: :info, flash: %{"info" => "Message sent"})

      assert html =~ ~s(phx-hook="AutoDismissFlash")
      assert html =~ ~s(data-flash="info")
      assert html =~ "Message sent"
    end

    test "tags an error notice with its own kind, so clearing it clears only that one" do
      html = render_component(&flash/1, kind: :error, flash: %{"error" => "Send failed"})

      assert html =~ ~s(data-flash="error")
      assert html =~ "Send failed"
    end

    test "renders nothing at all when there is no message" do
      assert render_component(&flash/1, kind: :info, flash: %{}) =~ ~r/\A\s*\z/
    end
  end
end
