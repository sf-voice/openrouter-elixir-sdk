defmodule PhoenixDemoWeb.ChatLiveTest do
  use PhoenixDemoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders the chat ui", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "openrouter_sdk demo"
    assert html =~ "streaming chat"
    assert html =~ "openai/gpt-4o-mini"
  end

  test "submitting an empty prompt is a no-op", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    rendered =
      view
      |> form("form[phx-submit=submit]", %{"prompt" => ""})
      |> render_submit()

    refute rendered =~ "streaming…"
  end
end
