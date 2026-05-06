defmodule OpenrouterSdk.OAuthTest do
  use ExUnit.Case, async: true

  import OpenrouterSdk.BypassHelpers

  alias OpenrouterSdk.OAuth

  test "generate_code_verifier produces a base64url string" do
    verifier = OAuth.generate_code_verifier()
    assert is_binary(verifier)
    # 64 random bytes -> ceil(64/3)*4 = 88 base64 chars, minus 1 padding char
    assert byte_size(verifier) >= 43
    refute String.contains?(verifier, "=")
  end

  test "code_challenge is deterministic for s256" do
    verifier = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGH"
    expected = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    assert OAuth.code_challenge(verifier, :s256) == expected
  end

  test "code_challenge with :plain returns the verifier as-is" do
    assert OAuth.code_challenge("xyz", :plain) == "xyz"
  end

  test "build_authorize_url includes callback and challenge" do
    url =
      OAuth.build_authorize_url("https://app.example.com/cb",
        code_challenge: "abc",
        code_challenge_method: :s256
      )

    assert String.starts_with?(url, "https://openrouter.ai/auth?")
    assert String.contains?(url, "callback_url=https%3A%2F%2Fapp.example.com%2Fcb")
    assert String.contains?(url, "code_challenge=abc")
    assert String.contains?(url, "code_challenge_method=S256")
  end

  test "exchange_code posts to /auth/keys and returns the api key" do
    {bypass, opts} = setup_bypass(api_key: nil)

    Bypass.expect_once(bypass, "POST", "/api/v1/auth/keys", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      assert payload["code"] == "the-code"
      assert payload["code_verifier"] == "the-verifier"
      assert payload["code_challenge_method"] == "S256"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"key" => "user-api-key"}))
    end)

    {:ok, body} =
      OAuth.exchange_code("the-code", [code_verifier: "the-verifier"] ++ opts)

    assert body["key"] == "user-api-key"
  end
end
