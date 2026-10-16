defmodule Tackle.Web.HealthControllerTest do
  use Tackle.Web.ConnCase, async: true

  test "GET /health answers 200 when the database is reachable", %{conn: conn} do
    conn = get(conn, "/health")

    assert json_response(conn, 200) == %{"status" => "ok"}
  end

  test "unknown routes answer a JSON 404 without details", %{conn: conn} do
    conn = get(conn, "/nope")

    assert json_response(conn, 404) == %{"errors" => %{"detail" => "Not Found"}}
  end
end
