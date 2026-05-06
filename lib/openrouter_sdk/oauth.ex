defmodule OpenrouterSdk.OAuth do
  @moduledoc """
  oauth pkce primitives.

  this is intentionally just the math + the http exchange. the
  consumer owns the redirect route, session storage, and the
  `code_verifier` lifetime.

  typical flow:

      verifier = OpenrouterSdk.OAuth.generate_code_verifier()
      challenge = OpenrouterSdk.OAuth.code_challenge(verifier)
      url = OpenrouterSdk.OAuth.build_authorize_url(
        "https://myapp.example.com/openrouter/callback",
        code_challenge: challenge,
        code_challenge_method: :s256
      )
      # redirect the user to `url`. on callback, exchange the code:
      {:ok, %{key: api_key}} =
        OpenrouterSdk.OAuth.exchange_code(
          conn.params["code"],
          code_verifier: verifier,
          code_challenge_method: :s256
        )
  """

  alias OpenrouterSdk.{Client, Config, Error}
  alias OpenrouterSdk.Client.Request

  @authorize_url "https://openrouter.ai/auth"
  @exchange_path "/auth/keys"
  @verifier_bytes 64

  @type method :: :s256 | :plain

  @doc """
  generate a cryptographically random code verifier (rfc 7636).

  uses 64 random bytes encoded as url-safe base64 (no padding) — well
  within the 43-128 char range the spec allows.
  """
  @spec generate_code_verifier() :: String.t()
  def generate_code_verifier do
    :crypto.strong_rand_bytes(@verifier_bytes)
    |> Base.url_encode64(padding: false)
  end

  @doc """
  derive the code_challenge from a verifier.

  defaults to s256 (recommended). pass `:plain` to skip hashing — only
  ever do that if the transport layer above can't hash, which is rare.
  """
  @spec code_challenge(String.t(), method()) :: String.t()
  def code_challenge(verifier, method \\ :s256)

  def code_challenge(verifier, :s256) when is_binary(verifier) do
    :crypto.hash(:sha256, verifier)
    |> Base.url_encode64(padding: false)
  end

  def code_challenge(verifier, :plain) when is_binary(verifier), do: verifier

  @doc """
  build the authorization url to redirect the user to.

  `callback_url` is required (where openrouter sends the user back
  with `?code=...`). `code_challenge` is technically optional per the
  api but you should always include it.
  """
  @spec build_authorize_url(String.t(), keyword()) :: String.t()
  def build_authorize_url(callback_url, opts \\ []) when is_binary(callback_url) do
    challenge = Keyword.get(opts, :code_challenge)
    method = Keyword.get(opts, :code_challenge_method, :s256)

    params =
      [{"callback_url", callback_url}]
      |> maybe_put("code_challenge", challenge)
      |> maybe_put("code_challenge_method", challenge && method_to_string(method))

    @authorize_url <> "?" <> URI.encode_query(params)
  end

  @doc """
  exchange an authorization code for an api key.

  returns `{:ok, %{key: "...", ...}}` on success — the full decoded
  json body is returned so future fields (user info, etc.) are
  available transparently.
  """
  @spec exchange_code(String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def exchange_code(code, opts \\ []) when is_binary(code) do
    verifier = Keyword.fetch!(opts, :code_verifier)
    method = Keyword.get(opts, :code_challenge_method, :s256)
    config = Config.merge(Config.new(opts), Keyword.take(opts, [:base_url, :finch_name]))

    payload = %{
      "code" => code,
      "code_verifier" => verifier,
      "code_challenge_method" => method_to_string(method)
    }

    req = %Request{
      method: :post,
      path: @exchange_path,
      body: {:json, payload},
      accept: :json
    }

    Client.request(req, config)
  end

  defp maybe_put(list, _key, nil), do: list
  defp maybe_put(list, _key, false), do: list
  defp maybe_put(list, key, value), do: list ++ [{key, to_string(value)}]

  defp method_to_string(:s256), do: "S256"
  defp method_to_string(:plain), do: "plain"
  defp method_to_string(other) when is_binary(other), do: other
end
