defmodule OpenrouterSdk do
  @moduledoc """
  thin facade for the most common operations.

  full module list:

    * `OpenrouterSdk.Api.Chat` — `/chat/completions`
    * `OpenrouterSdk.Api.Messages` — `/messages` (anthropic format)
    * `OpenrouterSdk.Api.Embeddings` — `/embeddings`
    * `OpenrouterSdk.Api.Speech` — `/audio/speech` (only works against a
      fixed allowlist of slugs not exposed via `/models` — prefer
      `OpenrouterSdk.speak/2`)
    * `OpenrouterSdk.Api.Transcription` — `/audio/transcriptions` (broken
      on openrouter today — prefer `OpenrouterSdk.transcribe/2`)
    * `OpenrouterSdk.Audio` — high-level transcribe + speak via
      `/chat/completions`. works against any catalog-listed audio model
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
  # higher-level audio helpers that go through /chat/completions and
  # work against any catalog-listed audio model. prefer these over
  # `speech/2` and `transcription/2` — see `OpenrouterSdk.Audio`.
  defdelegate transcribe(payload, opts \\ []), to: OpenrouterSdk.Audio
  defdelegate speak(payload, opts \\ []), to: OpenrouterSdk.Audio
  defdelegate models(opts \\ []), to: Api.Models, as: :list
end
