# phoenix_demo

minimal phoenix liveview app that dogfoods `openrouter_sdk` from the
parent repo via `{:openrouter_sdk, path: "../.."}`.

two modes at `/`:

- **text mode** — streaming chat completions via `OpenrouterSdk.chat_stream/2`,
  with a "speak" button on every assistant turn that hits
  `OpenrouterSdk.speech/1` for tts playback
- **voice mode** — turn-by-turn dialogue. tap mic to start a turn, tap
  to stop. `OpenrouterSdk.transcribe/2` turns the clip into text, the
  chat model replies (streamed), then tts plays the reply. ready for
  the next turn when the audio ends

every call routes through openrouter — single api key, no
provider-direct backdoors.

## run it

```bash
cd examples/phoenix_demo
mix setup                              # fetches deps, builds assets
cp .env.example .env                   # then paste your key into .env
set -a; source .env; set +a            # load it into the shell
mix phx.server
```

`.env` is gitignored. you'll need one key:

- `OPENROUTER_API_KEY` — chat + tts + stt. <https://openrouter.ai/keys>

then open <http://localhost:4000>.

## what it exercises

- finch pool wiring (started in `application.ex`)
- runtime config (`config/runtime.exs`)
- `OpenrouterSdk.chat_stream/2` with `:into pid` sink — sse parser,
  finch streaming bridge, streaming task lifecycle, all in a real
  beam process tree
- `OpenrouterSdk.speech/1` for batch tts, base64-piped to the browser
  via `push_event`
- `OpenrouterSdk.transcribe/2` — chat-completions-with-input_audio
  under the hood, single api call
- `OpenrouterSdk.Catalog.Models.{chat_models,tts_models,audio_input_models}/0`
  drive the model dropdowns at compile time, refreshed by
  `mix openrouter.snapshot` upstream

if you change the sdk in `lib/openrouter_sdk/` upstream, run
`mix deps.compile openrouter_sdk --force` here to pick it up — and
**restart `mix phx.server`**. phoenix's code reloader rebuilds app
modules on save but not path deps; the running beam will keep the
stale `OpenrouterSdk.*` modules loaded until you restart, and you'll
see `function OpenrouterSdk.<name>/N is undefined or private` until
you do.
