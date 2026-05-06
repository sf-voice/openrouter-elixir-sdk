defmodule OpenrouterSdk.MessagesTest do
  use ExUnit.Case, async: true

  import OpenrouterSdk.BypassHelpers
  alias OpenrouterSdk.Api.Messages

  test "create/2 hits /messages with stream: false" do
    {bypass, opts} = setup_bypass()

    Bypass.expect_once(bypass, "POST", "/api/v1/messages", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      assert payload["stream"] == false
      assert payload["max_tokens"] == 64

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"id" => "msg_1", "type" => "message"}))
    end)

    {:ok, body} =
      Messages.create(
        %{model: "anthropic/claude-sonnet-4-6", max_tokens: 64, messages: []},
        opts
      )

    assert body["id"] == "msg_1"
  end

  test "create_stream/2 emits typed event tuples for anthropic events" do
    {bypass, opts} = setup_bypass()

    chunks =
      sse_chunks([
        {:event, "message_start", ~s({"type":"message_start"})},
        {:event, "content_block_delta",
         ~s({"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}})},
        {:event, "message_stop", ~s({"type":"message_stop"})}
      ])

    Bypass.expect_once(bypass, "POST", "/api/v1/messages", fn conn ->
      stream_body(conn, chunks)
    end)

    {:ok, stream} =
      Messages.create_stream(%{model: "x", max_tokens: 1, messages: []}, opts)

    events = Enum.to_list(stream)

    assert [
             {"message_start", %{"type" => "message_start"}},
             {"content_block_delta", %{"delta" => %{"text" => "hi"}}},
             {"message_stop", %{"type" => "message_stop"}}
           ] = events
  end
end
