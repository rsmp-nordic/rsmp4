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
    test "formats standard topic correctly: id/type/code/component" do
      topic = Topic.new(@id, "status", "tlc", "plan", ["main"])
      assert to_string(topic) == "#{@id}/status/tlc.plan/main"
    end

    test "formats standard topic without component" do
      topic = Topic.new(@id, "status", "tlc", "plan", [])
      assert to_string(topic) == "#{@id}/status/tlc.plan"
    end

    test "formats presence topic correctly: id/presence" do
      topic = Topic.new(@id, "presence", nil, nil, [])
      assert to_string(topic) == "#{@id}/presence"
    end
  end

  describe "from_string/1" do
    test "parses standard topic: id/type/code/component" do
      string = "#{@id}/status/tlc.plan/main"
      topic = Topic.from_string(string)

      assert topic.type == "status"
      assert topic.path.module == "tlc"
      assert topic.path.code == "plan"
      assert topic.id == @id
      assert topic.path.component == ["main"]
    end

    test "parses standard topic without component" do
      string = "#{@id}/status/tlc.plan"
      topic = Topic.from_string(string)

      assert topic.type == "status"
      assert topic.path.module == "tlc"
      assert topic.path.code == "plan"
      assert topic.id == @id
      assert topic.path.component == []
    end

    test "parses presence topic" do
      string = "#{@id}/presence"
      topic = Topic.from_string(string)

      assert topic.type == "presence"
      assert topic.id == @id
    end
  end
end
