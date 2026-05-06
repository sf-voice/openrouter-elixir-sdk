defmodule OpenrouterSdk.ChatTest do
  use ExUnit.Case, async: true

  import OpenrouterSdk.BypassHelpers
  alias OpenrouterSdk.Api.Chat

  describe "completions/2" do
    test "buffered request returns the decoded body" do
      {bypass, opts} = setup_bypass()

      Bypass.expect_once(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)
        assert payload["model"] == "openai/gpt-4o-mini"
        assert payload["stream"] == false
        assert ["Bearer test-key"] = Plug.Conn.get_req_header(conn, "authorization")

        response = %{
          "id" => "cmp_1",
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "hi"}}]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      {:ok, body} =
        Chat.completions(
          %{model: "openai/gpt-4o-mini", messages: [%{role: "user", content: "hi"}]},
          opts
        )

      assert body["id"] == "cmp_1"
    end

    test "401 maps to an :auth error" do
      {bypass, opts} = setup_bypass()

      Bypass.expect_once(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(401, Jason.encode!(%{"error" => %{"message" => "unauthorized"}}))
      end)

      assert {:error, %OpenrouterSdk.Error{kind: :auth, retryable?: false}} =
               Chat.completions(%{model: "x", messages: []}, opts)
    end

    test "missing api key surfaces an error before any http call" do
      assert {:error, %OpenrouterSdk.Error{kind: :auth}} =
               Chat.completions(
                 %{model: "x", messages: []},
                 api_key: nil,
                 base_url: "http://localhost:1",
                 finch_name: OpenrouterSdk.TestFinch
               )
    end
  end

  describe "completions_stream/2" do
    test "yields decoded chunks and terminates on [DONE]" do
      {bypass, opts} = setup_bypass()

      chunks =
        sse_chunks([
          {:data, ~s({"choices":[{"delta":{"content":"hel"}}]})},
          {:data, ~s({"choices":[{"delta":{"content":"lo"}}]})},
          :done
        ])

      Bypass.expect_once(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        stream_body(conn, chunks)
      end)

      {:ok, stream} = Chat.completions_stream(%{model: "x", messages: []}, opts)
      events = Enum.to_list(stream)

      assert [
               {_, %{"choices" => [%{"delta" => %{"content" => "hel"}}]}},
               {_, %{"choices" => [%{"delta" => %{"content" => "lo"}}]}},
               :done
             ] = events
    end

    test ":into pid forwards events as messages" do
      {bypass, opts} = setup_bypass()

      chunks =
        sse_chunks([
          {:data, ~s({"choices":[{"delta":{"content":"a"}}]})},
          :done
        ])

      Bypass.expect_once(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        stream_body(conn, chunks)
      end)

      {:ok, ref} = Chat.completions_stream(%{model: "x", messages: []}, [{:into, self()} | opts])

      assert_receive {:openrouter_event, ^ref, {_, %{"choices" => _}}}, 2_000
      assert_receive {:openrouter_event, ^ref, :done}, 2_000
      assert_receive {:openrouter_event, ^ref, :complete}, 2_000
    end
  end
end
