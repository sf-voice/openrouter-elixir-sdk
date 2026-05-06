defmodule OpenrouterSdk.SpeechTest do
  use ExUnit.Case, async: true

  import OpenrouterSdk.BypassHelpers
  alias OpenrouterSdk.Api.Speech

  test "create/2 returns the raw audio bytes" do
    {bypass, opts} = setup_bypass()
    audio = <<1, 2, 3, 4, 5>>

    Bypass.expect_once(bypass, "POST", "/api/v1/audio/speech", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "audio/mpeg")
      |> Plug.Conn.resp(200, audio)
    end)

    assert {:ok, ^audio} =
             Speech.create(
               %{model: "openai/tts-1", input: "hi", voice: "alloy", response_format: "mp3"},
               opts
             )
  end
end
