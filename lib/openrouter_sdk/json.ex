defmodule OpenrouterSdk.JSON do
  @moduledoc """
  thin shim around json encode/decode.

  prefers the built-in `JSON` module that ships with elixir 1.18+. falls
  back to `Jason` if it's available — handy for hosts that already pull
  it in.
  """

  @doc "encode a term to an iodata json payload"
  @spec encode!(term()) :: iodata()
  def encode!(term) do
    if function_exported?(JSON, :encode_to_iodata!, 1) do
      JSON.encode_to_iodata!(term)
    else
      Jason.encode_to_iodata!(term)
    end
  end

  @doc "decode a json binary into elixir terms. returns {:ok, term} | {:error, reason}"
  @spec decode(binary()) :: {:ok, term()} | {:error, term()}
  def decode(binary) when is_binary(binary) do
    if function_exported?(JSON, :decode, 1) do
      JSON.decode(binary)
    else
      Jason.decode(binary)
    end
  end
end
