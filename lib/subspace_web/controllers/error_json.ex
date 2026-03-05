defmodule SubspaceWeb.ErrorJSON do
  @moduledoc false

  def render("404.json", _assigns), do: %{error: "not found", code: "NOT_FOUND"}
  def render("500.json", _assigns), do: %{error: "internal error", code: "INTERNAL_ERROR"}
  def render(_template, _assigns), do: %{error: "internal error", code: "INTERNAL_ERROR"}
end
