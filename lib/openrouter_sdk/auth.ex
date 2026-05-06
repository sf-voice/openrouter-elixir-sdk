defmodule OpenrouterSdk.Auth do
  @moduledoc """
  build the headers that authenticate a request.

  the api key may come from `%Config{}` or be overridden per call (the
  oauth flow returns a per-user key — consumers pass it via opts).
  """

  alias OpenrouterSdk.{Config, Error}

  @doc """
  produce the request headers for an authenticated call. returns
  `{:ok, headers}` or `{:error, %Error{}}` if no api key is available.
  """
  @spec headers(Config.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, Error.t()}
  def headers(%Config{api_key: nil}) do
    {:error,
     %Error{
       kind: :auth,
       message: "missing api key. set :openrouter_sdk, :api_key or pass api_key: ... to the call"
     }}
  end

  def headers(%Config{api_key: key}) when is_binary(key) do
    {:ok, [{"authorization", "Bearer " <> key}]}
  end
end
