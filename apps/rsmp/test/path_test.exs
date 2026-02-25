defmodule RSMP.PathTest do
  use ExUnit.Case

  describe "new/2" do
    test "creates a new path with code and component" do
      path = RSMP.Path.new("tlc.groups", ["sg", "1"])
      assert path.code == "tlc.groups"
      assert path.component == ["sg", "1"]
    end

    test "creates a path with default empty component" do
      path = RSMP.Path.new("tlc.plan")
      assert path.code == "tlc.plan"
      assert path.component == []
    end
  end

  describe "from_string/1" do
    test "creates a path from a string with component" do
      path = RSMP.Path.from_string("tlc.groups/sg/1")
      assert path.code == "tlc.groups"
      assert path.component == ["sg", "1"]
    end

    test "creates a path from a string without component" do
      path = RSMP.Path.from_string("tlc.plan")
      assert path.code == "tlc.plan"
      assert path.component == []
    end

    test "dots in code are preserved (not split)" do
      path = RSMP.Path.from_string("tlc.plan.set")
      assert path.code == "tlc.plan.set"
      assert path.component == []
    end
  end

  describe "to_string/1" do
    test "converts a path without component" do
      path = RSMP.Path.new("tlc.plan")
      assert to_string(path) == "tlc.plan"
    end

    test "converts a path with component" do
      path = RSMP.Path.new("tlc.groups", ["sg", "1"])
      assert to_string(path) == "tlc.groups/sg/1"
    end
  end
end
