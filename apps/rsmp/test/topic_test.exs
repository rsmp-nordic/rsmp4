defmodule RSMP.TopicTest do
  use ExUnit.Case
  alias RSMP.Topic

  describe "to_string/1" do
    test "formats standard topic correctly: type/module/code/id/component" do
      topic = Topic.new("my-node", "status", "tlc", "1", ["main"])
      assert to_string(topic) == "status/tlc/1/my-node/main"
    end

    test "formats standard topic without component" do
      topic = Topic.new("my-node", "status", "tlc", "1", [])
      assert to_string(topic) == "status/tlc/1/my-node"
    end

    test "formats presence topic correctly: presence/id" do
      topic = Topic.new("my-node", "presence", nil, nil, [])
      assert to_string(topic) == "presence/my-node"
    end
  end

  describe "from_string/1" do
    test "parses standard topic: type/module/code/id/component" do
      string = "status/tlc/1/my-node/main"
      topic = Topic.from_string(string)

      assert topic.type == "status"
      assert topic.path.module == "tlc"
      assert topic.path.code == "1"
      assert topic.id == "my-node"
      assert topic.path.component == ["main"]
    end

    test "parses standard topic without component" do
      string = "status/tlc/1/my-node"
      topic = Topic.from_string(string)

      assert topic.type == "status"
      assert topic.path.module == "tlc"
      assert topic.path.code == "1"
      assert topic.id == "my-node"
      assert topic.path.component == []
    end

    test "parses presence topic" do
      string = "presence/my-node"
      topic = Topic.from_string(string)

      assert topic.type == "presence"
      assert topic.id == "my-node"
    end
  end
end
