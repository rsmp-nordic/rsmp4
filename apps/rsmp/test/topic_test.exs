defmodule RSMP.TopicTest do
  use ExUnit.Case
  alias RSMP.Topic

  # Use a 3-part ID to match default config :topic_prefix_levels = 3
  @id "region/zone/my-node"

  describe "to_string/1" do
    test "formats standard topic correctly: id/type/code/component" do
      topic = Topic.new(@id, "status", "tlc", "1", ["main"])
      assert to_string(topic) == "#{@id}/status/tlc.1/main"
    end

    test "formats standard topic without component" do
      topic = Topic.new(@id, "status", "tlc", "1", [])
      assert to_string(topic) == "#{@id}/status/tlc.1"
    end

    test "formats presence topic correctly: id/presence" do
      topic = Topic.new(@id, "presence", nil, nil, [])
      assert to_string(topic) == "#{@id}/presence"
    end
  end

  describe "from_string/1" do
    test "parses standard topic: id/type/code/component" do
      string = "#{@id}/status/tlc.1/main"
      topic = Topic.from_string(string)

      assert topic.type == "status"
      assert topic.path.module == "tlc"
      assert topic.path.code == "1"
      assert topic.id == @id
      assert topic.path.component == ["main"]
    end

    test "parses standard topic without component" do
      string = "#{@id}/status/tlc.1"
      topic = Topic.from_string(string)

      assert topic.type == "status"
      assert topic.path.module == "tlc"
      assert topic.path.code == "1"
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
