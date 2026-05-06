defmodule OpenrouterSdk do
  @moduledoc """
  thin facade for the most common operations.

  full module list:

    * `OpenrouterSdk.Api.Chat` — `/chat/completions`
    * `OpenrouterSdk.Api.Messages` — `/messages` (anthropic format)
    * `OpenrouterSdk.Api.Embeddings` — `/embeddings`
    * `OpenrouterSdk.Api.Speech` — `/audio/speech`
    * `OpenrouterSdk.Api.Transcription` — `/audio/transcriptions`
    * `OpenrouterSdk.Api.Models` — live `/models`
    * `OpenrouterSdk.Catalog.Models` — embedded snapshot
    * `OpenrouterSdk.Catalog.Providers` — embedded snapshot
    * `OpenrouterSdk.OAuth` — pkce primitives
    * `OpenrouterSdk.Middleware` — extension behaviour
    * `OpenrouterSdk.Config`, `OpenrouterSdk.Error`

  the package ships zero retry / rotation policy on purpose. compose
  your own via the `Middleware` behaviour.
  """

  alias OpenrouterSdk.Api

  defdelegate chat(payload, opts \\ []), to: Api.Chat, as: :completions
  defdelegate chat_stream(payload, opts \\ []), to: Api.Chat, as: :completions_stream
  defdelegate messages(payload, opts \\ []), to: Api.Messages, as: :create
  defdelegate messages_stream(payload, opts \\ []), to: Api.Messages, as: :create_stream
  defdelegate embeddings(payload, opts \\ []), to: Api.Embeddings, as: :create
  defdelegate speech(payload, opts \\ []), to: Api.Speech, as: :create
  defdelegate transcription(payload, opts \\ []), to: Api.Transcription, as: :create
  defdelegate models(opts \\ []), to: Api.Models, as: :list
end
