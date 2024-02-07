defmodule RSMP.Client.Web.ClientLiveTest do
  use RSMP.Client.Web.ConnCase

  import Phoenix.LiveViewTest
  import RSMP.MeasurementsFixtures

  @create_attrs %{}
  @update_attrs %{}
  @invalid_attrs %{}

  defp create_temperature(_) do
    temperature = temperature_fixture()
    %{temperature: temperature}
  end

  describe "Index" do
    setup [:create_temperature]

    test "lists all temperatures", %{conn: conn} do
      {:ok, _index_live, html} = live(conn, ~p"/temperatures")

      assert html =~ "Listing Temperatures"
    end

    test "saves new temperature", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/temperatures")

      assert index_live |> element("a", "New Temperature") |> render_click() =~
               "New Temperature"

      assert_patch(index_live, ~p"/temperatures/new")

      assert index_live
             |> form("#temperature-form", temperature: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert index_live
             |> form("#temperature-form", temperature: @create_attrs)
             |> render_submit()

      assert_patch(index_live, ~p"/temperatures")

      html = render(index_live)
      assert html =~ "Temperature created successfully"
    end

    test "updates temperature in listing", %{conn: conn, temperature: temperature} do
      {:ok, index_live, _html} = live(conn, ~p"/temperatures")

      assert index_live |> element("#temperatures-#{temperature.id} a", "Edit") |> render_click() =~
               "Edit Temperature"

      assert_patch(index_live, ~p"/temperatures/#{temperature}/edit")

      assert index_live
             |> form("#temperature-form", temperature: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert index_live
             |> form("#temperature-form", temperature: @update_attrs)
             |> render_submit()

      assert_patch(index_live, ~p"/temperatures")

      html = render(index_live)
      assert html =~ "Temperature updated successfully"
    end

    test "deletes temperature in listing", %{conn: conn, temperature: temperature} do
      {:ok, index_live, _html} = live(conn, ~p"/temperatures")

      assert index_live
             |> element("#temperatures-#{temperature.id} a", "Delete")
             |> render_click()

      refute has_element?(index_live, "#temperatures-#{temperature.id}")
    end
  end

  describe "Show" do
    setup [:create_temperature]

    test "displays temperature", %{conn: conn, temperature: temperature} do
      {:ok, _show_live, html} = live(conn, ~p"/temperatures/#{temperature}")

      assert html =~ "Show Temperature"
    end

    test "updates temperature within modal", %{conn: conn, temperature: temperature} do
      {:ok, show_live, _html} = live(conn, ~p"/temperatures/#{temperature}")

      assert show_live |> element("a", "Edit") |> render_click() =~
               "Edit Temperature"

      assert_patch(show_live, ~p"/temperatures/#{temperature}/show/edit")

      assert show_live
             |> form("#temperature-form", temperature: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert show_live
             |> form("#temperature-form", temperature: @update_attrs)
             |> render_submit()

      assert_patch(show_live, ~p"/temperatures/#{temperature}")

      html = render(show_live)
      assert html =~ "Temperature updated successfully"
    end
  end
end
