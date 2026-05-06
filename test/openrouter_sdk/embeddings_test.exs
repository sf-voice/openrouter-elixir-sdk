defmodule OpenrouterSdk.EmbeddingsTest do
  use ExUnit.Case, async: true

  import OpenrouterSdk.BypassHelpers
  alias OpenrouterSdk.Api.Embeddings

  test "create/2 posts to /embeddings and returns vectors" do
    {bypass, opts} = setup_bypass()

    Bypass.expect_once(bypass, "POST", "/api/v1/embeddings", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      assert payload["input"] == ["a", "b"]

      response = %{"data" => [%{"embedding" => [0.1, 0.2], "index" => 0}]}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(response))
    end)

    {:ok, %{"data" => [%{"embedding" => emb}]}} =
      Embeddings.create(%{model: "openai/text-embedding-3-small", input: ["a", "b"]}, opts)

    assert emb == [0.1, 0.2]
  end
end
