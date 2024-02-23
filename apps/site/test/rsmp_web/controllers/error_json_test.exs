defmodule RSMP.Site.Web.ErrorJSONTest do
  use RSMP.Site.Web.ConnCase, async: true

  test "renders 404" do
    assert RSMP.Site.Web.ErrorJSON.render("404.json", %{}) == %{
             errors: %{detail: "Not Found"}
           }
  end

  test "renders 500" do
    assert RSMP.Site.Web.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
