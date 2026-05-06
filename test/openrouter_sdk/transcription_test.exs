defmodule OpenrouterSdk.TranscriptionTest do
  use ExUnit.Case, async: true

  import OpenrouterSdk.BypassHelpers
  alias OpenrouterSdk.Api.Transcription

  test "create/2 sends a multipart body with the file part" do
    {bypass, opts} = setup_bypass()

    Bypass.expect_once(bypass, "POST", "/api/v1/audio/transcriptions", fn conn ->
      [content_type] = Plug.Conn.get_req_header(conn, "content-type")
      assert String.starts_with?(content_type, "multipart/form-data; boundary=")

      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 1_000_000)
      assert body =~ ~s(name="file")
      assert body =~ ~s(filename="clip.wav")
      assert body =~ ~s(name="model")
      assert body =~ "openai/whisper-1"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"text" => "hello world"}))
    end)

    {:ok, %{"text" => text}} =
      Transcription.create(
        %{
          file: {"clip.wav", <<0, 1, 2, 3>>, "audio/wav"},
          model: "openai/whisper-1",
          language: "en"
        },
        opts
      )

    assert text == "hello world"
  end
end
