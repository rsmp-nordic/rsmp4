defmodule RSMP.PathTest do
  use ExUnit.Case

  describe "new/1" do
    test "creates a new path from element names" do
      path = RSMP.Path.new("my_mod", "my_code", ["my_comp"])
      assert RSMP.Path.to_list(path) == ["my_mod", "my_code", "my_comp"]
    end
  end

  describe "to_list/1" do
    test "converts a path to its list of element names" do
      path = RSMP.Path.new("mod", "code", ["comp"])
      assert RSMP.Path.to_list(path) == ["mod", "code", "comp"]
    end
  end

  describe "from_string/1" do
    test "creates a path from a string" do
      path = RSMP.Path.from_string("my_mod/my_code/my_comp")
      assert RSMP.Path.to_list(path) == ["my_mod", "my_code", "my_comp"]
    end
  end

  describe "to_string/1" do
    test "converts a path to its string representation" do
      path = RSMP.Path.new("mod", "code", ["comp"])
      assert to_string(path) == "mod/code/comp"
    end
  end
end
