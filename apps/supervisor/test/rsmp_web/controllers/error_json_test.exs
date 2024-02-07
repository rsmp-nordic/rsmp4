defmodule RSMP.Supervisor.Web.ErrorJSONTest do
  use RSMP.Supervisor.Web.ConnCase, async: true

  test "renders 404" do
    assert RSMP.Supervisor.Web.ErrorJSON.render("404.json", %{}) == %{
             errors: %{detail: "Not Found"}
           }
  end

  test "renders 500" do
    assert RSMP.Supervisor.Web.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
