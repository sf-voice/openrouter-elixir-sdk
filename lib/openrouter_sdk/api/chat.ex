defmodule OpenrouterSdk.Api.Chat do
  @moduledoc """
  `POST /chat/completions` — openai-compatible chat.

  buffered:

      OpenrouterSdk.Api.Chat.completions(%{
        model: "openai/gpt-4o-mini",
        messages: [%{role: "user", content: "hello"}]
      })

  streaming:

      {:ok, stream} = OpenrouterSdk.Api.Chat.completions_stream(%{
        model: "openai/gpt-4o-mini",
        messages: [%{role: "user", content: "hello"}]
      })

      Enum.each(stream, &IO.inspect/1)
  """

  alias OpenrouterSdk.{Client, Config, Streaming}
  alias OpenrouterSdk.Client.Request

  @path "/chat/completions"

  @spec completions(map(), keyword()) :: {:ok, map()} | {:error, OpenrouterSdk.Error.t()}
  def completions(payload, opts \\ []) when is_map(payload) do
    config = Config.merge(Config.new(opts), opts)

    %Request{
      method: :post,
      path: @path,
      body: {:json, Map.put(payload, :stream, false)},
      accept: :json
    }
    |> Client.request(config)
  end

  @spec completions_stream(map(), keyword()) ::
          {:ok, Enumerable.t() | reference() | term()} | {:error, OpenrouterSdk.Error.t()}
  def completions_stream(payload, opts \\ []) when is_map(payload) do
    config = Config.merge(Config.new(opts), opts)

    request = %Request{
      method: :post,
      path: @path,
      body: {:json, Map.put(payload, :stream, true)},
      accept: :sse,
      opts: Keyword.take(opts, [:raw, :decode])
    }

    Streaming.wrap(fn -> Client.stream(request, config) end, opts)
  end
end
