defmodule ChatAgent.Channel.MessageTest do
  use ExUnit.Case, async: true

  alias ChatAgent.Channel.Message

  doctest Message

  describe "new/1" do
    test "drops identifiers the payload had no value for" do
      message =
        Message.new(
          sender: "1",
          conversation: "1",
          text: "Hello",
          identifiers: [{"a", 1}, {"b", nil}, {"c", ""}, {"d", "keep"}]
        )

      assert message.identifiers == [{"a", "1"}, {"d", "keep"}]
    end

    test "defaults received_at to now" do
      before = DateTime.utc_now()
      message = Message.new(sender: "1", conversation: "1", text: "Hello")

      assert DateTime.compare(message.received_at, before) in [:eq, :gt]
    end

    test "leaves identifiers empty when none are given" do
      assert Message.new(sender: "1", conversation: "1", text: "Hello").identifiers == []
    end

    test "treats a message as inbound unless told otherwise" do
      assert Message.new(sender: "1", conversation: "1", text: "Hello").direction == :inbound

      assert Message.new(sender: "you", conversation: "1", text: "Hi", direction: :outbound).direction ==
               :outbound
    end
  end
end
