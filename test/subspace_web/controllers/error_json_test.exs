defmodule SubspaceWeb.ErrorJSONTest do
  use SubspaceWeb.ConnCase, async: true

  test "renders 404" do
    assert SubspaceWeb.ErrorJSON.render("404.json", %{}) == %{
             error: "not found",
             code: "NOT_FOUND"
           }
  end

  test "renders 500" do
    assert SubspaceWeb.ErrorJSON.render("500.json", %{}) ==
             %{error: "internal error", code: "INTERNAL_ERROR"}
  end
end
