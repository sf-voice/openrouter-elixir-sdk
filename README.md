# openrouter_sdk

elixir sdk for [openrouter](https://openrouter.ai). thin, finch-based,
ships zero policy.

supports:

- chat completions (openai-compatible) — buffered + sse streaming
- anthropic messages (`/v1/messages`) — buffered + sse streaming
- embeddings
- speech (text-to-speech) and transcription (speech-to-text)
- bearer api keys + oauth 2 pkce primitives
- a hard-coded snapshot of all models + providers, refreshed nightly by
  ci with an auto-opened pr when openrouter ships drift

retries, exponential backoff, model rotation, and circuit breakers
are intentionally **not** in this package. compose them yourself via
the `OpenrouterSdk.Middleware` behaviour.

## install

```elixir
def deps do
  [
    {:openrouter_sdk, "~> 0.1.0"}
  ]
end
```

```elixir
# config/runtime.exs
config :openrouter_sdk,
  api_key: System.get_env("OPENROUTER_API_KEY"),
  default_headers: [
    {"http-referer", "https://yourapp.com"},
    {"x-title", "Your App"}
  ]
```

start a finch pool somewhere in your supervision tree (or set
`auto_start_finch: true` to let the sdk start one):

```elixir
children = [
  {Finch, name: OpenrouterSdk.Finch}
  # ...
]
```

## quick examples

### chat (buffered)

```elixir
{:ok, response} =
  OpenrouterSdk.chat(%{
    model: "openai/gpt-4o-mini",
    messages: [%{role: "user", content: "what's the capital of france?"}]
  })

response["choices"] |> hd() |> get_in(["message", "content"])
```

### chat (streaming)

```elixir
{:ok, stream} =
  OpenrouterSdk.chat_stream(%{
    model: "openai/gpt-4o-mini",
    messages: [%{role: "user", content: "tell me a story"}]
  })

stream
|> Stream.flat_map(fn
  {_, %{"choices" => [%{"delta" => %{"content" => c}} | _]}} when is_binary(c) -> [c]
  _ -> []
end)
|> Enum.each(&IO.write/1)
```

### chat (streaming via pid — useful for liveview)

```elixir
{:ok, ref} = OpenrouterSdk.chat_stream(payload, into: self())

receive do
  {:openrouter_event, ^ref, event} -> handle(event)
  {:openrouter_event, ^ref, :complete} -> :done
end
```

### anthropic messages

```elixir
{:ok, msg} =
  OpenrouterSdk.messages(%{
    model: "anthropic/claude-sonnet-4-6",
    max_tokens: 1024,
    messages: [%{role: "user", content: "hi"}]
  })
```

streaming yields `{event_name, decoded_payload}` tuples
(`"message_start"`, `"content_block_delta"`, `"message_stop"`, ...).

### embeddings

```elixir
{:ok, %{"data" => vectors}} =
  OpenrouterSdk.embeddings(%{
    model: "openai/text-embedding-3-small",
    input: ["the quick brown fox", "jumped over the lazy dog"]
  })
```

### speech (tts)

```elixir
{:ok, mp3} =
  OpenrouterSdk.speech(%{
    model: "openai/tts-1",
    input: "hello there",
    voice: "alloy",
    response_format: "mp3"
  })

File.write!("hello.mp3", mp3)
```

### transcription (stt)

```elixir
{:ok, %{"text" => text}} =
  OpenrouterSdk.transcription(%{
    file: "recording.wav",
    model: "openai/whisper-1",
    language: "en"
  })
```

## oauth pkce

end-user auth (each user brings their own openrouter account):

```elixir
verifier = OpenrouterSdk.OAuth.generate_code_verifier()
challenge = OpenrouterSdk.OAuth.code_challenge(verifier)

# stash `verifier` somewhere keyed by the user's session, then redirect:
url =
  OpenrouterSdk.OAuth.build_authorize_url(
    "https://yourapp.com/openrouter/callback",
    code_challenge: challenge,
    code_challenge_method: :s256
  )

# on the callback, after the user grants access:
{:ok, %{"key" => api_key}} =
  OpenrouterSdk.OAuth.exchange_code(
    conn.params["code"],
    code_verifier: verifier
  )

# pass the per-user key on every call:
OpenrouterSdk.chat(payload, api_key: api_key)
```

no plug helpers, no token storage — you own the redirect route.

## custom middleware (retry / rotation / backoff)

```elixir
defmodule MyApp.Retry do
  @behaviour OpenrouterSdk.Middleware

  @impl true
  def call(req, next, opts) do
    max = Keyword.get(opts, :max, 3)
    attempt(req, next, max)
  end

  defp attempt(req, next, 0), do: next.(req)

  defp attempt(req, next, remaining) do
    case next.(req) do
      {:error, %{retryable?: true}} = _err ->
        Process.sleep(:rand.uniform(200) * (4 - remaining))
        attempt(req, next, remaining - 1)

      result ->
        result
    end
  end
end
```

```elixir
config :openrouter_sdk,
  middleware: [
    {MyApp.Retry, max: 3},
    {MyApp.RotateOnExhaustion, models: ["openai/gpt-4o-mini", "anthropic/claude-haiku-4-5"]}
  ]
```

middleware sees every request (buffered + the start of streams). per-chunk
events flow directly to your stream consumer.

## models / providers catalog

`OpenrouterSdk.Catalog.Models.list/0` returns the embedded snapshot —
zero-io, refreshed by ci. use it to drive your own rotation logic:

```elixir
OpenrouterSdk.Catalog.Models.list(modality: "text")
OpenrouterSdk.Catalog.Models.get("anthropic/claude-sonnet-4-6")
OpenrouterSdk.Catalog.Models.context_length("openai/gpt-4o-mini")
```

if you want a live read instead, call `OpenrouterSdk.models/0` (hits
`/api/v1/models` over the wire).

### refreshing the snapshot manually

```bash
mix openrouter.snapshot          # write fresh snapshot
mix openrouter.snapshot --check  # verify against upstream (ci pr gate)
```

a daily github actions workflow runs `mix openrouter.snapshot` and
opens a pr titled `chore: refresh openrouter catalog` whenever the
upstream catalog has drifted.

## errors

every public function returns `{:ok, term}` or `{:error, %OpenrouterSdk.Error{}}`.

```elixir
%OpenrouterSdk.Error{
  kind: :rate_limit,    # :transport | :timeout | :auth | :rate_limit | :payment_required
                        # | :invalid_request | :server | :stream_disconnect | :decode
  status: 429,
  code: "rate_limited",
  message: "...",
  retryable?: true,     # the signal middleware uses
  body: ...             # the raw decoded upstream body
}
```

## telemetry

every request emits `[:openrouter_sdk, :request, :start | :stop | :exception]`
spans. attach with `:telemetry.attach/4` for tracing.
