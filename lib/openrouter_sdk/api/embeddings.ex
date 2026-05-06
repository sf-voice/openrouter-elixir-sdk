defmodule OpenrouterSdk.Api.Embeddings do
  @moduledoc """
  `POST /embeddings` — convert text (or multimodal content) to vectors.

      OpenrouterSdk.Api.Embeddings.create(%{
        model: "openai/text-embedding-3-small",
        input: ["hello world", "another sentence"]
      })
  """

  alias OpenrouterSdk.{Client, Config}
  alias OpenrouterSdk.Client.Request

  @path "/embeddings"

  @spec create(map(), keyword()) :: {:ok, map()} | {:error, OpenrouterSdk.Error.t()}
  def create(payload, opts \\ []) when is_map(payload) do
    config = Config.merge(Config.new(opts), opts)

    %Request{
      method: :post,
      path: @path,
      body: {:json, payload},
      accept: :json
    }
    |> Client.request(config)
  end
end
