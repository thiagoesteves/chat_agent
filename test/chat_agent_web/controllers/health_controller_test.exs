defmodule ChatAgentWeb.HealthControllerTest do
  use ChatAgentWeb.ConnCase, async: true

  describe "health/2" do
    test "answers 200 with an ok status", %{conn: conn} do
      conn = get(conn, ~p"/health")

      assert %{"status" => "ok"} = json_response(conn, 200)
    end

    test "reports the time it answered, as ISO8601", %{conn: conn} do
      before = DateTime.utc_now()
      conn = get(conn, ~p"/health")
      after_answer = DateTime.utc_now()

      assert %{"timestamp" => timestamp} = json_response(conn, 200)
      assert {:ok, answered_at, _offset} = DateTime.from_iso8601(timestamp)
      assert DateTime.compare(answered_at, before) in [:gt, :eq]
      assert DateTime.compare(answered_at, after_answer) in [:lt, :eq]
    end

    test "answers as JSON", %{conn: conn} do
      conn = get(conn, ~p"/health")

      assert {"content-type", "application/json; charset=utf-8"} in conn.resp_headers
    end
  end
end
