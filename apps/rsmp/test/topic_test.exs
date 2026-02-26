defmodule RSMP.TopicTest do
  use ExUnit.Case
  alias RSMP.Topic

  # Use a 3-part ID to match default config :topic_prefix_levels = 3
  @id "region/zone/my-node"

  setup do
    old_level = Application.get_env(:rsmp, :topic_prefix_levels)
    Application.put_env(:rsmp, :topic_prefix_levels, 3)
    on_exit(fn ->
      if old_level do
        Application.put_env(:rsmp, :topic_prefix_levels, old_level)
      else
        Application.delete_env(:rsmp, :topic_prefix_levels)
      end
    end)
    :ok
  end

  describe "to_string/1" do
    test "formats status topic with channel name" do
      topic = Topic.new(@id, "status", "tlc.plan", "main")
      assert to_string(topic) == "#{@id}/status/tlc.plan/main"
    end

    test "formats status topic without channel name" do
      topic = Topic.new(@id, "status", "tlc.plan")
      assert to_string(topic) == "#{@id}/status/tlc.plan"
    end

    test "formats presence topic correctly: id/presence" do
      topic = Topic.new(@id, "presence", nil)
      assert to_string(topic) == "#{@id}/presence"
    end

    test "formats command topic" do
      topic = Topic.new(@id, "command", "tlc.plan.set")
      assert to_string(topic) == "#{@id}/command/tlc.plan.set"
    end
  end

  describe "from_string/1" do
    test "parses status topic with channel name" do
      string = "#{@id}/status/tlc.plan/main"
      topic = Topic.from_string(string)

      assert topic.type == "status"
      assert topic.path.code == "tlc.plan"
      assert topic.id == @id
      assert topic.channel_name == "main"
    end

    test "parses status topic without channel name" do
      string = "#{@id}/status/tlc.plan"
      topic = Topic.from_string(string)

      assert topic.type == "status"
      assert topic.path.code == "tlc.plan"
      assert topic.id == @id
      assert topic.channel_name == nil
    end

    test "parses command topic (no channel name concept)" do
      string = "#{@id}/command/tlc.plan.set"
      topic = Topic.from_string(string)

      assert topic.type == "command"
      assert topic.path.code == "tlc.plan.set"
      assert topic.channel_name == nil
    end

    test "parses presence topic" do
      string = "#{@id}/presence"
      topic = Topic.from_string(string)

      assert topic.type == "presence"
      assert topic.id == @id
    end
  end
end
