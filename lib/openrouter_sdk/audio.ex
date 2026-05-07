defmodule OpenrouterSdk.Audio do
  @moduledoc """
  high-level audio helpers built on top of `/chat/completions`.

  why this module exists alongside `Api.Speech` and `Api.Transcription`:
  the dedicated `/audio/speech` and `/audio/transcriptions` endpoints
  on openrouter accept a fixed allowlist of model slugs that aren't
  exposed via `/models`, so consumers can't discover them via the
  catalog. transcription via multipart is also broken at the gateway
  level (you'll see `No number after minus sign in JSON at position 1`
  from v8 choking on `--<boundary>`).

  the catalog *does* list audio-input and audio-output chat models —
  `gpt-audio`, `gpt-audio-mini`, `gemini-2.5-flash`, `voxtral`, etc. —
  and the documented `/chat/completions` `input_audio` (stt) and
  `audio` modality (tts) paths work against any of them. that's what
  this module wraps.

    * `transcribe/2` — audio → text, picks from
      `OpenrouterSdk.Catalog.Models.audio_input_models/0`
    * `speak/2` — text → audio, picks from
      `OpenrouterSdk.Catalog.Models.tts_models/0`
  """

  alias OpenrouterSdk.Api.Chat

  @default_prompt "Transcribe the audio verbatim. Reply with only the transcription, no commentary, no explanations."

  @doc """
  transcribe a binary audio clip via chat completions + input_audio.

      {:ok, "hello world"} =
        OpenrouterSdk.Audio.transcribe(%{
          audio: File.read!("clip.webm"),
          mime: "audio/webm",
          model: "google/gemini-2.5-flash"
        })

  ## options on the payload
    * `:audio` (required) — the raw audio bytes
    * `:mime` (required) — content type. `audio/webm`, `audio/mp4`,
      `audio/wav`, `audio/mpeg`, `audio/ogg`, `audio/flac` all work
    * `:model` (required) — an audio-input chat model id
    * `:prompt` (optional) — overrides the default verbatim
      instruction. use this if you want translation, formatting, etc.

  the second argument is forwarded to `OpenrouterSdk.Api.Chat.completions/2`
  so you can pass `:config_overrides`, custom middleware, etc.
  """
  @spec transcribe(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def transcribe(payload, opts \\ [])

  def transcribe(%{audio: binary, mime: mime, model: model} = payload, opts)
      when is_binary(binary) and is_binary(mime) and is_binary(model) do
    prompt = Map.get(payload, :prompt) || @default_prompt
    format = mime_to_format(mime)

    body = %{
      model: model,
      messages: [
        %{
          role: "user",
          content: [
            %{type: "text", text: prompt},
            %{
              type: "input_audio",
              input_audio: %{data: Base.encode64(binary), format: format}
            }
          ]
        }
      ]
    }

    case Chat.completions(body, opts) do
      {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _]}}
      when is_binary(content) ->
        {:ok, String.trim(content)}

      {:ok, other} ->
        {:error, "unexpected chat response shape: #{inspect(other)}"}

      {:error, _} = err ->
        err
    end
  end

  # webm/opus is what chrome's MediaRecorder produces by default but
  # isn't in openrouter's documented format list. it's literally the
  # same opus codec as ogg/opus, just a different container header,
  # and the audio-input models accept it as "ogg" without complaint.
  defp mime_to_format("audio/webm" <> _), do: "ogg"
  defp mime_to_format("audio/ogg" <> _), do: "ogg"
  defp mime_to_format("audio/mp4" <> _), do: "m4a"
  defp mime_to_format("audio/mpeg" <> _), do: "mp3"
  defp mime_to_format("audio/wav" <> _), do: "wav"
  defp mime_to_format("audio/flac" <> _), do: "flac"
  defp mime_to_format("audio/x-flac"), do: "flac"
  defp mime_to_format(_), do: "ogg"

  @default_voice "alloy"
  @default_format "mp3"

  @doc """
  generate speech audio from text via `/chat/completions` with an
  audio output modality.

      {:ok, mp3_binary} =
        OpenrouterSdk.Audio.speak(%{
          text: "hello there",
          model: "openai/gpt-audio-mini"
        })

      File.write!("hello.mp3", mp3_binary)

  ## options on the payload
    * `:text` (required) — the text to read aloud
    * `:model` (required) — an audio-output chat model id (e.g.
      from `OpenrouterSdk.Catalog.Models.tts_models/0`)
    * `:voice` — defaults to `"alloy"`. accepts whatever the chosen
      model's provider supports
    * `:format` — defaults to `"mp3"`. accepts `"mp3"`, `"wav"`,
      `"opus"`, `"flac"` etc. depending on provider

  returns the raw audio bytes — the helper base64-decodes the
  response audio for you.
  """
  @spec speak(map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def speak(payload, opts \\ [])

  def speak(%{text: text, model: model} = payload, opts)
      when is_binary(text) and is_binary(model) do
    voice = Map.get(payload, :voice) || @default_voice
    format = Map.get(payload, :format) || @default_format

    body = %{
      model: model,
      modalities: ["text", "audio"],
      audio: %{voice: voice, format: format},
      messages: [%{role: "user", content: text}]
    }

    case Chat.completions(body, opts) do
      {:ok, %{"choices" => [%{"message" => %{"audio" => %{"data" => b64}}} | _]}}
      when is_binary(b64) ->
        case Base.decode64(b64) do
          {:ok, bytes} -> {:ok, bytes}
          :error -> {:error, "could not decode base64 audio in response"}
        end

      {:ok, other} ->
        {:error, "no audio in chat response: #{inspect(other)}"}

      {:error, _} = err ->
        err
    end
  end
end
