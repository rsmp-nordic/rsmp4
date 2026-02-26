defmodule RSMP.PathTest do
  use ExUnit.Case

  describe "new/1" do
    test "creates a new path with code" do
      path = RSMP.Path.new("tlc.groups")
      assert path.code == "tlc.groups"
    end
  end

  describe "from_string/1" do
    test "creates a path from a string" do
      path = RSMP.Path.from_string("tlc.plan")
      assert path.code == "tlc.plan"
    end

    test "dots in code are preserved (not split)" do
      path = RSMP.Path.from_string("tlc.plan.set")
      assert path.code == "tlc.plan.set"
    end
  end

  describe "to_string/1" do
    test "converts a path to string" do
      path = RSMP.Path.new("tlc.plan")
      assert to_string(path) == "tlc.plan"
    end
  end
end
