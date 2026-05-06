defmodule OpenrouterSdk.Api.Models do
  @moduledoc """
  `GET /models` — live model catalog.

  this hits the api every call. if you want a stable hard-coded view,
  use `OpenrouterSdk.Catalog.Models` instead — that's the snapshot
  embedded into the package and refreshed by ci.
  """

  alias OpenrouterSdk.{Client, Config}
  alias OpenrouterSdk.Client.Request

  @path "/models"

  @spec list(keyword()) :: {:ok, map()} | {:error, OpenrouterSdk.Error.t()}
  def list(opts \\ []) do
    config = Config.merge(Config.new(opts), opts)
    query = Keyword.take(opts, [:category, :supported_parameters, :output_modalities])

    %Request{
      method: :get,
      path: @path,
      query: query,
      accept: :json
    }
    |> Client.request(config)
  end
end
