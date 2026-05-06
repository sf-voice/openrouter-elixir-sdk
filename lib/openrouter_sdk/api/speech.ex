defmodule OpenrouterSdk.Api.Speech do
  @moduledoc """
  `POST /audio/speech` — text-to-speech.

      {:ok, mp3_binary} = OpenrouterSdk.Api.Speech.create(%{
        model: "openai/tts-1",
        input: "hello there",
        voice: "alloy",
        response_format: "mp3"
      })

      File.write!("hello.mp3", mp3_binary)

  the response is the raw audio bytes — we do NOT decode json on this
  endpoint.
  """

  alias OpenrouterSdk.{Client, Config, Streaming}
  alias OpenrouterSdk.Client.Request

  @path "/audio/speech"

  @spec create(map(), keyword()) ::
          {:ok, binary()} | {:error, OpenrouterSdk.Error.t()}
  def create(payload, opts \\ []) when is_map(payload) do
    config = Config.merge(Config.new(opts), opts)

    %Request{
      method: :post,
      path: @path,
      body: {:json, payload},
      accept: :binary
    }
    |> Client.request(config)
  end

  @doc """
  stream the audio response as a `Stream` of byte chunks. consumers
  who want pid / fun delivery pass `:into` exactly like the chat
  streaming api.
  """
  @spec create_stream(map(), keyword()) ::
          {:ok, Enumerable.t() | reference() | term()} | {:error, OpenrouterSdk.Error.t()}
  def create_stream(payload, opts \\ []) when is_map(payload) do
    config = Config.merge(Config.new(opts), opts)

    request = %Request{
      method: :post,
      path: @path,
      body: {:json, payload},
      accept: :sse,
      opts: [decode: false, raw: true]
    }

    Streaming.wrap(fn -> Client.stream(request, config) end, opts)
  end
end
