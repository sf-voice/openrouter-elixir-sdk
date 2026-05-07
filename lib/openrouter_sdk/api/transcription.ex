defmodule OpenrouterSdk.Api.Transcription do
  @moduledoc """
  `POST /audio/transcriptions` — speech-to-text via the dedicated
  endpoint.

  the upstream endpoint is openai-compatible: multipart upload with a
  `file` part plus a `model` field.

      {:ok, %{"text" => text}} =
        OpenrouterSdk.Api.Transcription.create(%{
          file: {"recording.wav", File.read!("recording.wav"), "audio/wav"},
          model: "openai/whisper-1",
          language: "en"
        })

  > #### caveat {: .warning}
  >
  > openrouter's gateway currently json-parses the request body and
  > rejects multipart uploads — a real call against this endpoint
  > returns `400` with `No number after minus sign in JSON at
  > position 1` (v8's json parser choking on the `--<boundary>`
  > preamble). until that ships properly, prefer
  > `OpenrouterSdk.transcribe/2` (in `OpenrouterSdk.Audio`), which
  > routes through `/chat/completions` with an `input_audio` content
  > block and works against any catalog-listed audio-input model.
  """

  alias OpenrouterSdk.{Client, Config}
  alias OpenrouterSdk.Client.Request

  @path "/audio/transcriptions"

  @spec create(map(), keyword()) :: {:ok, map()} | {:error, OpenrouterSdk.Error.t()}
  def create(payload, opts \\ []) when is_map(payload) do
    config = Config.merge(Config.new(opts), opts)
    parts = build_parts(payload)

    %Request{
      method: :post,
      path: @path,
      body: {:multipart, parts},
      accept: :json
    }
    |> Client.request(config)
  end

  defp build_parts(payload) do
    {file, rest} = Map.pop(payload, :file)

    file_part =
      case file do
        {filename, binary, content_type} ->
          {:file, "file", filename, content_type, binary}

        path when is_binary(path) ->
          {:file, "file", Path.basename(path), guess_mime(path), File.read!(path)}

        nil ->
          raise ArgumentError, "transcription requires a :file (path | {name, binary, mime})"
      end

    field_parts =
      Enum.map(rest, fn {k, v} ->
        {:field, to_string(k), to_string(v)}
      end)

    [file_part | field_parts]
  end

  defp guess_mime(path) do
    case Path.extname(path) |> String.downcase() do
      ".wav" -> "audio/wav"
      ".mp3" -> "audio/mpeg"
      ".m4a" -> "audio/mp4"
      ".ogg" -> "audio/ogg"
      ".flac" -> "audio/flac"
      ".webm" -> "audio/webm"
      _ -> "application/octet-stream"
    end
  end
end
