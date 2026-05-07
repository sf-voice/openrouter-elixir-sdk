defmodule PhoenixDemoWeb.ChatLive do
  @moduledoc """
  chat demo against the openrouter sdk, plus turn-by-turn voice mode.

  every call routes through openrouter — single api key, no
  provider-direct backdoors. all three flows go through
  `/chat/completions`; the audio helpers (`speak/2`, `transcribe/2`)
  just wrap input_audio / output_audio modalities.

  ## chat (streaming sse)
    * user submits a prompt -> we append a user message + an empty
      assistant message to `:messages`
    * we kick off `OpenrouterSdk.chat_stream(payload, into: self())`
    * the sdk task forwards `{:openrouter_event, ref, event}` messages
      into this liveview's mailbox; we accumulate `delta.content` into
      the trailing assistant message and re-render

  ## stt (turn-by-turn)
    * voice mode shows a big mic button. tap to start a turn, tap to
      stop. the `VoiceMic` hook records via `MediaRecorder` and ships
      the base64 blob to the lv as a `voice_audio` event
    * the lv calls `OpenrouterSdk.transcribe/2` async; the resulting
      text is fed through the same chat path as a typed prompt

  ## tts (batch)
    * "speak" button on a finished assistant bubble (text mode) or
      automatically after each assistant turn (voice mode) hits
      `OpenrouterSdk.speak/2`
    * the mp3 bytes are base64'd and pushed via `play_audio` for the
      browser to play through a single shared `Audio` element. for
      voice mode, the player fires `voice:audio_done` so the
      `VoiceConvo` hook can drive the next turn
  """

  use PhoenixDemoWeb, :live_view

  require Logger

  # model lists are sourced from the sdk's compile-time catalog
  # (`mix openrouter.snapshot` keeps it fresh) so we never have to
  # hardcode or maintain a list here. sorted alphabetically by name
  # so the dropdown is predictable.
  @chat_models OpenrouterSdk.Catalog.Models.chat_models()
               |> Enum.map(&{&1["id"], &1["name"] || &1["id"]})
               |> Enum.sort_by(fn {_id, name} -> String.downcase(name) end)

  @tts_models OpenrouterSdk.Catalog.Models.tts_models()
              |> Enum.map(&{&1["id"], &1["name"] || &1["id"]})
              |> Enum.sort_by(fn {_id, name} -> String.downcase(name) end)

  # stt now goes through /chat/completions with input_audio (see
  # `OpenrouterSdk.transcribe/2`), so the "stt model" is just any
  # audio-input chat model.
  @stt_models OpenrouterSdk.Catalog.Models.audio_input_models()
              |> Enum.map(&{&1["id"], &1["name"] || &1["id"]})
              |> Enum.sort_by(fn {_id, name} -> String.downcase(name) end)

  @default_chat_model "openai/gpt-4o-mini"
  @default_tts_model "openai/gpt-audio-mini"
  @default_tts_voice "alloy"
  @default_stt_model "google/gemini-2.5-flash"

  @example_prompts [
    "explain elixir's actor model in one paragraph",
    "write a haiku about server-sent events",
    "what's the difference between GenServer and Task?"
  ]

  # canned greeting played when a fresh voice session starts. fixed
  # text by design — gives the demo a consistent opening and lets the
  # tts cache work for free across sessions.
  @greeting_text "Hi, this is an OpenRouter demo. What can I help you with today?"

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:model, @default_chat_model)
      |> assign(:tts_model, @default_tts_model)
      |> assign(:tts_voice, @default_tts_voice)
      |> assign(:stt_model, @default_stt_model)
      |> assign(:input, "")
      |> assign(:streaming?, false)
      |> assign(:speaking_idx, nil)
      |> assign(:stream_ref, nil)
      |> assign(:error, nil)
      |> assign(:messages, [])
      # voice/conversation mode. :text is the original chat ui;
      # :voice swaps in the turn-by-turn voice ui at the same url.
      |> assign(:mode, :text)
      # voice session state machine:
      # :idle | :greeting | :listening | :transcribing | :thinking | :speaking | :ended
      |> assign(:voice_state, :idle)

    {:ok, socket}
  end

  @impl true
  def handle_event("update_settings", params, socket) do
    {:noreply,
     socket
     |> assign(:model, params["model"] || socket.assigns.model)
     |> assign(:tts_model, params["tts_model"] || socket.assigns.tts_model)
     |> assign(:stt_model, params["stt_model"] || socket.assigns.stt_model)}
  end

  # keep `:input` in sync with the textarea so a re-render doesn't
  # clobber what the user typed.
  def handle_event("update_input", %{"prompt" => prompt}, socket) do
    {:noreply, assign(socket, :input, prompt)}
  end

  def handle_event("submit", %{"prompt" => prompt}, socket)
      when is_binary(prompt) and prompt != "" do
    if socket.assigns.streaming? do
      {:noreply, socket}
    else
      send(self(), {:start_stream, prompt})

      # morphdom won't clear a focused textarea, so push the empty
      # value down explicitly so the box resets after send.
      {:noreply,
       socket
       |> assign(input: "")
       |> push_event("set_input", %{value: ""})}
    end
  end

  def handle_event("submit", _params, socket), do: {:noreply, socket}

  def handle_event("clear", _params, socket) do
    {:noreply, assign(socket, messages: [], error: nil)}
  end

  def handle_event("speak", %{"idx" => idx}, socket) do
    idx = String.to_integer(idx)

    case Enum.at(socket.assigns.messages, idx) do
      %{role: "assistant", content: content} when content != "" ->
        kick_tts(self(), socket, content, kind: {:manual, idx})
        {:noreply, assign(socket, speaking_idx: idx, error: nil)}

      _ ->
        {:noreply, socket}
    end
  end

  # ----- voice mode -----

  def handle_event("enter_voice", _params, socket) do
    {:noreply, assign(socket, mode: :voice, voice_state: :idle, error: nil)}
  end

  def handle_event("exit_voice", _params, socket) do
    {:noreply,
     socket
     |> assign(:mode, :text)
     |> assign(:voice_state, :idle)
     |> push_event("voice_session_stop", %{})}
  end

  def handle_event("start_voice_session", _params, socket) do
    if socket.assigns.voice_state != :idle do
      {:noreply, socket}
    else
      greeting = %{role: "assistant", content: @greeting_text, streaming?: false, voice?: true}
      messages = socket.assigns.messages ++ [greeting]

      socket =
        socket
        |> assign(:messages, messages)
        |> assign(:voice_state, :greeting)
        |> assign(:error, nil)

      send(self(), {:voice_tts, @greeting_text})
      push_memory(socket)

      {:noreply, socket}
    end
  end

  # user finished recording a turn — base64 audio arrives from the
  # voiceconvo hook. transcribe async then feed it through the same
  # path as a typed prompt.
  def handle_event("voice_audio", %{"audio" => b64, "mime" => mime}, socket) do
    case Base.decode64(b64) do
      {:ok, binary} when byte_size(binary) > 0 ->
        pid = self()
        model = socket.assigns.stt_model

        Task.start(fn ->
          # everything routes through openrouter — the sdk wraps the
          # documented /chat/completions input_audio path internally.
          case OpenrouterSdk.transcribe(%{audio: binary, mime: mime, model: model}) do
            {:ok, text} -> send(pid, {:voice_transcript, text})
            {:error, error} -> send(pid, {:voice_transcript_error, format_error(error)})
          end
        end)

        {:noreply, assign(socket, voice_state: :transcribing, error: nil)}

      _ ->
        # empty / malformed blob — drop it and stay in :listening.
        {:noreply, socket}
    end
  end

  def handle_event("end_voice_session", _params, socket) do
    if socket.assigns.voice_state in [:idle, :ended] do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:voice_state, :ended)
       |> push_event("voice_session_stop", %{})}
    end
  end

  def handle_event("voice_reset", _params, socket) do
    {:noreply, assign(socket, voice_state: :idle)}
  end

  # localstorage rehydration — only seed `:messages` if we're cold.
  def handle_event("restore_memory", %{"messages" => messages}, socket)
      when is_list(messages) do
    if socket.assigns.messages == [] and socket.assigns.voice_state == :idle do
      restored =
        messages
        |> Enum.filter(&valid_restored_message?/1)
        |> Enum.map(&restore_message/1)

      {:noreply, assign(socket, :messages, restored)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("restore_memory", _params, socket), do: {:noreply, socket}

  # browser tells us tts playback finished. in voice mode this drives
  # the transition back to :listening so the user can take their next
  # turn.
  def handle_event("voice_audio_ended", _params, socket) do
    if socket.assigns.mode == :voice and socket.assigns.voice_state == :speaking do
      {:noreply, assign(socket, voice_state: :listening)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:start_stream, prompt}, socket) do
    user_msg = %{role: "user", content: prompt}
    assistant_msg = %{role: "assistant", content: "", streaming?: true}
    messages = socket.assigns.messages ++ [user_msg, assistant_msg]

    payload = %{model: socket.assigns.model, messages: build_history(messages)}

    case OpenrouterSdk.chat_stream(payload, into: self()) do
      {:ok, ref} ->
        {:noreply,
         socket
         |> assign(:messages, messages)
         |> assign(:streaming?, true)
         |> assign(:stream_ref, ref)
         |> assign(:error, nil)}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(:messages, socket.assigns.messages ++ [user_msg])
         |> assign(:error, format_error(error))}
    end
  end

  def handle_info({:openrouter_event, ref, event}, %{assigns: %{stream_ref: ref}} = socket) do
    {:noreply, handle_stream_event(event, socket)}
  end

  def handle_info({:openrouter_event, _stale_ref, _event}, socket), do: {:noreply, socket}

  def handle_info({:tts_ready, kind, mp3}, socket) do
    src = "data:audio/mp3;base64,#{Base.encode64(mp3)}"

    socket =
      case kind do
        {:manual, _idx} -> assign(socket, :speaking_idx, nil)
        :voice -> assign(socket, voice_state: :speaking)
        _ -> socket
      end

    # `then: "voice_audio_ended"` tells the audio player to fire the
    # ended-event back to the lv, which drives the next turn.
    payload =
      case kind do
        :voice -> %{src: src, then: "voice_audio_ended"}
        _ -> %{src: src}
      end

    {:noreply, push_event(socket, "play_audio", payload)}
  end

  def handle_info({:tts_error, kind, error}, socket) do
    Logger.error("tts failed: #{inspect(error)}")

    socket =
      case kind do
        {:manual, _idx} -> assign(socket, :speaking_idx, nil)
        :voice -> assign(socket, voice_state: :listening)
        _ -> socket
      end

    {:noreply, assign(socket, :error, "speech failed: #{format_error(error)}")}
  end

  # ----- voice mode handle_infos -----

  def handle_info({:voice_tts, text}, socket) do
    kick_tts(self(), socket, text, kind: :voice)
    {:noreply, assign(socket, voice_state: :speaking)}
  end

  def handle_info({:voice_transcript, ""}, socket) do
    # transcription came back empty — most likely silence. just rewind.
    {:noreply, assign(socket, voice_state: :listening)}
  end

  def handle_info({:voice_transcript, text}, socket) do
    text = String.trim(text)

    if text == "" do
      {:noreply, assign(socket, voice_state: :listening)}
    else
      user_msg = %{role: "user", content: text, voice?: true}
      assistant_msg = %{role: "assistant", content: "", streaming?: true, voice?: true}
      messages = socket.assigns.messages ++ [user_msg, assistant_msg]

      payload = %{model: socket.assigns.model, messages: build_history(messages)}

      case OpenrouterSdk.chat_stream(payload, into: self()) do
        {:ok, ref} ->
          socket =
            socket
            |> assign(:messages, messages)
            |> assign(:streaming?, true)
            |> assign(:stream_ref, ref)
            |> assign(:voice_state, :thinking)

          push_memory(socket)
          {:noreply, socket}

        {:error, error} ->
          {:noreply,
           socket
           |> assign(:messages, socket.assigns.messages ++ [user_msg])
           |> assign(:voice_state, :listening)
           |> assign(:error, format_error(error))}
      end
    end
  end

  def handle_info({:voice_transcript_error, reason}, socket) do
    Logger.error("voice transcribe failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:voice_state, :listening)
     |> assign(:error, "transcription failed: #{reason}")}
  end

  def handle_info({:voice_skip_tts}, socket) do
    {:noreply, assign(socket, voice_state: :listening)}
  end

  defp handle_stream_event(:complete, socket), do: finish_stream(socket)
  defp handle_stream_event(:done, socket), do: finish_stream(socket)

  defp handle_stream_event({_event_name, %{"choices" => choices}}, socket) do
    delta_text =
      choices
      |> Enum.map(&get_in(&1, ["delta", "content"]))
      |> Enum.find(&is_binary/1)

    if delta_text, do: append_assistant_chunk(socket, delta_text), else: socket
  end

  defp handle_stream_event(_other, socket), do: socket

  defp append_assistant_chunk(socket, chunk) do
    messages =
      List.update_at(socket.assigns.messages, -1, fn last ->
        %{last | content: last.content <> chunk}
      end)

    assign(socket, :messages, messages)
  end

  defp finish_stream(socket) do
    messages =
      List.update_at(socket.assigns.messages, -1, fn last ->
        %{last | streaming?: false}
      end)

    socket =
      socket
      |> assign(:messages, messages)
      |> assign(:streaming?, false)
      |> assign(:stream_ref, nil)

    # in voice mode, immediately speak the just-completed assistant
    # turn instead of waiting for a click.
    if socket.assigns.mode == :voice and socket.assigns.voice_state == :thinking do
      assistant_text =
        case List.last(messages) do
          %{role: "assistant", content: c} when is_binary(c) and c != "" -> c
          _ -> ""
        end

      if assistant_text != "" do
        send(self(), {:voice_tts, assistant_text})
      else
        # nothing to speak — go straight back to listening
        send(self(), {:voice_skip_tts})
      end

      push_memory(socket)
    end

    socket
  end

  defp build_history(messages) do
    messages
    |> Enum.reject(&(&1.role == "assistant" and Map.get(&1, :streaming?, false)))
    |> Enum.map(&Map.take(&1, [:role, :content]))
  end

  # ----- tts kickoff (shared by manual + voice paths) -----

  defp kick_tts(pid, socket, text, opts) do
    kind = Keyword.fetch!(opts, :kind)

    payload = %{
      model: socket.assigns.tts_model,
      text: text,
      voice: socket.assigns.tts_voice,
      format: "mp3"
    }

    Task.start(fn ->
      # speak/2 routes through /chat/completions with audio output —
      # the only path that actually works against catalog-listed
      # audio models on openrouter today.
      case OpenrouterSdk.speak(payload) do
        {:ok, mp3} -> send(pid, {:tts_ready, kind, mp3})
        {:error, error} -> send(pid, {:tts_error, kind, error})
      end
    end)
  end

  # ----- localstorage memory -----

  defp push_memory(socket) do
    payload = %{
      messages:
        Enum.map(socket.assigns.messages, fn msg ->
          %{
            "role" => msg.role,
            "content" => msg.content,
            "voice" => Map.get(msg, :voice?, false)
          }
        end)
    }

    push_event(socket, "save_memory", payload)
  end

  defp valid_restored_message?(%{"role" => role, "content" => content})
       when role in ["user", "assistant"] and is_binary(content),
       do: true

  defp valid_restored_message?(_), do: false

  defp restore_message(%{"role" => role, "content" => content} = m) do
    %{
      role: role,
      content: content,
      streaming?: false,
      voice?: Map.get(m, "voice", false)
    }
  end

  defp format_error(%OpenrouterSdk.Error{kind: kind, message: msg, status: status}) do
    "openrouter error (#{kind}#{if status, do: " #{status}", else: ""}): #{msg}"
  end

  defp format_error(other), do: inspect(other)

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:example_prompts, @example_prompts)
      |> assign(:chat_models, @chat_models)
      |> assign(:tts_models, @tts_models)
      |> assign(:stt_models, @stt_models)

    ~H"""
    <div id="root" phx-hook="MemoryStore" class="mx-auto flex h-screen max-w-3xl flex-col px-4 py-6">
      <header class="flex items-center justify-between gap-4 pb-3">
        <div class="flex items-center gap-3">
          <div class="flex h-9 w-9 items-center justify-center rounded-lg bg-base-300/60 ring-1 ring-base-300">
            <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.75" stroke="currentColor" class="h-4 w-4 text-primary">
              <path stroke-linecap="round" stroke-linejoin="round" d="M8.25 7.5h7.5M8.25 12h4.5m-6.75 7.5L3 21V5.25A2.25 2.25 0 0 1 5.25 3h13.5A2.25 2.25 0 0 1 21 5.25v10.5A2.25 2.25 0 0 1 18.75 18H8.25l-3 3Z" />
            </svg>
          </div>
          <div>
            <h1 class="text-sm font-semibold leading-tight tracking-tight">openrouter_sdk</h1>
            <p class="text-[11px] text-base-content/50">phoenix liveview · chat · stt · tts</p>
          </div>
        </div>

        <%= if @mode == :text do %>
          <button type="button" phx-click="enter_voice"
            class="inline-flex items-center gap-1.5 rounded-full border border-primary/30 bg-primary/10 px-3 py-1 text-[11px] font-medium uppercase tracking-wider text-primary transition hover:bg-primary/20"
            title="switch to voice conversation">
            <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="2" stroke="currentColor" class="h-3 w-3">
              <path stroke-linecap="round" stroke-linejoin="round" d="M12 18.75a6 6 0 0 0 6-6v-1.5m-6 7.5a6 6 0 0 1-6-6v-1.5m6 7.5v3.75m-3.75 0h7.5M12 15.75a3 3 0 0 1-3-3V4.5a3 3 0 1 1 6 0v8.25a3 3 0 0 1-3 3Z" />
            </svg>
            voice
          </button>
        <% else %>
          <button type="button" phx-click="exit_voice"
            class="inline-flex items-center gap-1.5 rounded-full border border-base-300 bg-base-200 px-3 py-1 text-[11px] font-medium uppercase tracking-wider text-base-content/70 transition hover:bg-base-300"
            title="switch back to text">
            text
          </button>
        <% end %>
      </header>

      <%= if @mode == :text do %>
        <.text_mode_panel
          model={@model}
          tts_model={@tts_model}
          stt_model={@stt_model}
          chat_models={@chat_models}
          tts_models={@tts_models}
          stt_models={@stt_models}
          messages={@messages}
          input={@input}
          streaming?={@streaming?}
          speaking_idx={@speaking_idx}
          error={@error}
          example_prompts={@example_prompts}
        />
      <% else %>
        <.voice_panel
          voice_state={@voice_state}
          messages={@messages}
          error={@error}
          speaking_idx={@speaking_idx}
        />
      <% end %>
    </div>
    """
  end

  # ----- text mode panel -----

  attr :model, :string, required: true
  attr :tts_model, :string, required: true
  attr :stt_model, :string, required: true
  attr :chat_models, :list, required: true
  attr :tts_models, :list, required: true
  attr :stt_models, :list, required: true
  attr :messages, :list, required: true
  attr :input, :string, required: true
  attr :streaming?, :boolean, required: true
  attr :speaking_idx, :any, required: true
  attr :error, :string, default: nil
  attr :example_prompts, :list, required: true

  defp text_mode_panel(assigns) do
    ~H"""
    <form phx-change="update_settings" class="grid grid-cols-1 gap-2 pb-4 sm:grid-cols-3">
      <.field_select label="chat model" name="model" options={@chat_models} value={@model} />
      <.field_select label="voice (tts)" name="tts_model" options={@tts_models} value={@tts_model} />
      <.field_select label="voice (stt)" name="stt_model" options={@stt_models} value={@stt_model} />
    </form>

    <div
      id="messages"
      phx-hook="ScrollBottom"
      class="flex-1 space-y-5 overflow-y-auto rounded-2xl border border-base-300/80 bg-base-100/40 p-4 sm:p-6"
    >
      <%= if @messages == [] do %>
        <div class="flex h-full flex-col items-center justify-center gap-6 py-8 text-center">
          <div class="flex h-12 w-12 items-center justify-center rounded-full bg-primary/10 text-primary ring-1 ring-primary/20">
            <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="h-5 w-5">
              <path stroke-linecap="round" stroke-linejoin="round" d="M3.75 13.5 12 6l8.25 7.5M5.25 11.25v8.25h13.5v-8.25" />
            </svg>
          </div>
          <div>
            <p class="text-sm font-medium">start a conversation</p>
            <p class="mt-1 text-xs text-base-content/50">type, or switch to voice mode.</p>
          </div>
          <div class="flex w-full max-w-md flex-col gap-1.5">
            <button :for={prompt <- @example_prompts} type="button" phx-click="submit" phx-value-prompt={prompt}
              class="rounded-lg border border-base-300/60 bg-base-200/40 px-3.5 py-2.5 text-left text-xs text-base-content/70 transition hover:border-primary/40 hover:bg-base-200 hover:text-base-content">
              {prompt}
            </button>
          </div>
        </div>
      <% end %>

      <div :for={{msg, idx} <- Enum.with_index(@messages)} class={"flex gap-3 #{if msg.role == "user", do: "flex-row-reverse"}"}>
        <div class={avatar_class(msg)}>{avatar_label(msg)}</div>
        <div class={"flex max-w-[85%] flex-col gap-1 #{if msg.role == "user", do: "items-end"}"}>
          <div class="flex items-center gap-2 text-[10px] uppercase tracking-wider text-base-content/35">
            <span>{msg.role}</span>
            <button :if={speakable?(msg)} type="button" phx-click="speak" phx-value-idx={idx}
              class="inline-flex items-center gap-1 rounded px-1.5 py-0.5 normal-case tracking-normal text-base-content/45 transition hover:bg-base-200 hover:text-base-content disabled:opacity-50"
              disabled={@speaking_idx == idx} title="play with text-to-speech">
              <%= if @speaking_idx == idx do %>
                <span class="loading loading-spinner loading-xs"></span>
                loading
              <% else %>
                <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="2" stroke="currentColor" class="h-3 w-3">
                  <path stroke-linecap="round" stroke-linejoin="round" d="M19.114 5.636a9 9 0 0 1 0 12.728M16.463 8.288a5.25 5.25 0 0 1 0 7.424M6.75 8.25l4.72-4.72a.75.75 0 0 1 1.28.53v15.88a.75.75 0 0 1-1.28.53l-4.72-4.72H4.51c-.88 0-1.704-.507-1.938-1.354A9.009 9.009 0 0 1 2.25 12c0-.83.112-1.633.322-2.396C2.806 8.756 3.63 8.25 4.51 8.25H6.75Z" />
                </svg>
                speak
              <% end %>
            </button>
          </div>
          <div class={bubble_class(msg)}>
            <div class="whitespace-pre-wrap text-sm leading-relaxed">{msg.content}<span :if={cursor?(msg)} class="ml-0.5 inline-block w-2 animate-pulse">▍</span></div>
          </div>
          <div :if={idx == length(@messages) - 1 && @error} class="text-xs text-error">{@error}</div>
        </div>
      </div>

      <div :if={@error && @messages == []} class="rounded-lg border border-error/30 bg-error/10 p-3 text-xs text-error">
        {@error}
      </div>
    </div>

    <form phx-submit="submit" phx-change="update_input" class="mt-4 flex items-end gap-1.5 rounded-2xl border border-base-300/80 bg-base-200/50 p-2 transition focus-within:border-primary/50 focus-within:bg-base-200/80">
      <textarea
        name="prompt"
        placeholder="ask anything…"
        autocomplete="off"
        rows="1"
        phx-hook="EnterToSubmit"
        id="prompt-input"
        class="flex-1 resize-none border-0 bg-transparent px-2 py-2 text-sm leading-relaxed text-base-content placeholder:text-base-content/30 focus:outline-none focus:ring-0 max-h-40"
        disabled={@streaming?}
      ><%= @input %></textarea>

      <button type="button" phx-click="clear" class="btn btn-ghost btn-sm"
        disabled={@streaming? or @messages == []} title="clear conversation">
        clear
      </button>
      <button type="submit" class="btn btn-primary btn-sm gap-1.5" disabled={@streaming?}>
        <%= if @streaming? do %>
          <span class="loading loading-spinner loading-xs"></span>
          <span class="hidden sm:inline">streaming</span>
        <% else %>
          <span class="hidden sm:inline">send</span>
          <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="2" stroke="currentColor" class="h-3.5 w-3.5">
            <path stroke-linecap="round" stroke-linejoin="round" d="M6 12 3.269 3.125A59.769 59.769 0 0 1 21.485 12 59.768 59.768 0 0 1 3.27 20.875L5.999 12Zm0 0h7.5" />
          </svg>
        <% end %>
      </button>
    </form>

    <p class="mt-2 text-center text-[11px] text-base-content/30">
      enter to send · shift+enter for newline · switch to voice for dictation
    </p>
    """
  end

  # ----- shared field select -----

  attr :label, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, required: true
  attr :options, :list, required: true

  defp field_select(assigns) do
    ~H"""
    <label class="flex flex-col gap-1">
      <span class="text-[10px] uppercase tracking-wider text-base-content/40">{@label}</span>
      <select name={@name}
        class="select select-sm select-bordered border-base-300 bg-base-200/40 font-mono text-xs hover:bg-base-200/80 focus:border-primary/60">
        <option :for={{slug, label} <- @options} value={slug} selected={slug == @value}>
          {label}
        </option>
      </select>
    </label>
    """
  end

  # ----- voice panel -----

  attr :voice_state, :atom, required: true
  attr :messages, :list, required: true
  attr :error, :string, default: nil
  attr :speaking_idx, :any, default: nil

  # voice mode body. one of three layouts depending on state:
  #   :idle   -> "tap to start" hero
  #   :ended  -> playback list
  #   else    -> live transcript + mic controls
  defp voice_panel(%{voice_state: :idle} = assigns) do
    ~H"""
    <div class="flex flex-1 flex-col items-center justify-center gap-6 rounded-2xl border border-base-300/80 bg-base-100/40 p-6 text-center">
      <div class="flex h-16 w-16 items-center justify-center rounded-full bg-primary/10 text-primary ring-1 ring-primary/30">
        <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="h-8 w-8">
          <path stroke-linecap="round" stroke-linejoin="round" d="M12 18.75a6 6 0 0 0 6-6v-1.5m-6 7.5a6 6 0 0 1-6-6v-1.5m6 7.5v3.75m-3.75 0h7.5M12 15.75a3 3 0 0 1-3-3V4.5a3 3 0 1 1 6 0v8.25a3 3 0 0 1-3 3Z" />
        </svg>
      </div>
      <div>
        <p class="text-base font-medium">voice conversation</p>
        <p class="mt-1 text-xs text-base-content/50">
          turn-by-turn · audio model transcribes · tts replies
        </p>
      </div>
      <button type="button" phx-click="start_voice_session" class="btn btn-primary btn-sm gap-2">
        start conversation
      </button>
      <div :if={@error} class="text-xs text-error">{@error}</div>
    </div>
    """
  end

  defp voice_panel(%{voice_state: :ended} = assigns) do
    ~H"""
    <div class="flex flex-1 flex-col gap-4 overflow-hidden">
      <div class="flex-1 space-y-4 overflow-y-auto rounded-2xl border border-base-300/80 bg-base-100/40 p-5">
        <p class="px-1 pb-2 text-[10px] uppercase tracking-wider text-base-content/40">conversation playback</p>
        <ul class="space-y-2">
          <li :for={{msg, idx} <- assistant_turns(@messages)} class="flex items-start gap-2 rounded-lg border border-base-300/60 bg-base-200/40 p-3">
            <button type="button" phx-click="speak" phx-value-idx={idx}
              class="btn btn-ghost btn-xs btn-circle"
              disabled={@speaking_idx == idx} title="play this turn">
              <%= if @speaking_idx == idx do %>
                <span class="loading loading-spinner loading-xs"></span>
              <% else %>
                <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="2" stroke="currentColor" class="h-3.5 w-3.5">
                  <path stroke-linecap="round" stroke-linejoin="round" d="M5.25 5.25 19.5 12 5.25 18.75V5.25Z" />
                </svg>
              <% end %>
            </button>
            <p class="flex-1 text-xs leading-relaxed text-base-content/80">{msg.content}</p>
          </li>
        </ul>
      </div>

      <div class="flex items-center justify-between gap-2">
        <button type="button" phx-click="voice_reset" class="btn btn-primary btn-sm">
          new conversation
        </button>
        <button type="button" phx-click="exit_voice" class="btn btn-ghost btn-sm">
          back to text
        </button>
      </div>
    </div>
    """
  end

  defp voice_panel(assigns) do
    ~H"""
    <div class="flex flex-1 flex-col gap-3 overflow-hidden">
      <div
        id="voice-messages"
        phx-hook="ScrollBottom"
        class="flex-1 space-y-4 overflow-y-auto rounded-2xl border border-base-300/80 bg-base-100/40 p-5"
      >
        <div :for={{msg, idx} <- Enum.with_index(@messages)} class={"flex gap-3 #{if msg.role == "user", do: "flex-row-reverse"}"}>
          <div class={avatar_class(msg)}>{avatar_label(msg)}</div>
          <div class={"flex max-w-[85%] flex-col gap-1 #{if msg.role == "user", do: "items-end"}"}>
            <div class="text-[10px] uppercase tracking-wider text-base-content/35">{msg.role}</div>
            <div class={bubble_class(msg)}>
              <div class="whitespace-pre-wrap text-sm leading-relaxed">{msg.content}<span :if={cursor?(msg)} class="ml-0.5 inline-block w-2 animate-pulse">▍</span></div>
            </div>
            <div :if={idx == length(@messages) - 1 && @error} class="text-xs text-error">{@error}</div>
          </div>
        </div>
      </div>

      <div
        id="voice-convo"
        phx-hook="VoiceConvo"
        class="flex flex-col items-center gap-3 rounded-2xl border border-base-300/80 bg-base-200/50 px-4 py-5"
      >
        <button
          type="button"
          id="voice-mic"
          data-state={@voice_state}
          phx-hook="VoiceMic"
          class={voice_mic_class(@voice_state)}
          disabled={@voice_state in [:greeting, :transcribing, :thinking, :speaking]}
          aria-label={voice_mic_label(@voice_state)}
        >
          <%= if @voice_state == :listening do %>
            <span data-mic-idle>
              <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="h-7 w-7">
                <path stroke-linecap="round" stroke-linejoin="round" d="M12 18.75a6 6 0 0 0 6-6v-1.5m-6 7.5a6 6 0 0 1-6-6v-1.5m6 7.5v3.75m-3.75 0h7.5M12 15.75a3 3 0 0 1-3-3V4.5a3 3 0 1 1 6 0v8.25a3 3 0 0 1-3 3Z" />
              </svg>
            </span>
            <span data-mic-recording class="hidden">
              <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="h-6 w-6">
                <rect x="6" y="6" width="12" height="12" rx="2" />
              </svg>
            </span>
          <% else %>
            <%= if @voice_state in [:transcribing, :thinking] do %>
              <span class="loading loading-spinner loading-md"></span>
            <% else %>
              <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="h-7 w-7 opacity-40">
                <path stroke-linecap="round" stroke-linejoin="round" d="M12 18.75a6 6 0 0 0 6-6v-1.5m-6 7.5a6 6 0 0 1-6-6v-1.5m6 7.5v3.75m-3.75 0h7.5M12 15.75a3 3 0 0 1-3-3V4.5a3 3 0 1 1 6 0v8.25a3 3 0 0 1-3 3Z" />
              </svg>
            <% end %>
          <% end %>
        </button>

        <p class="text-[11px] uppercase tracking-wider text-base-content/55">
          {voice_label(@voice_state)}
        </p>

        <button type="button" phx-click="end_voice_session" class="btn btn-ghost btn-xs text-base-content/50">
          end conversation
        </button>
      </div>
    </div>
    """
  end

  defp voice_label(:greeting), do: "greeting…"
  defp voice_label(:listening), do: "tap to speak"
  defp voice_label(:transcribing), do: "transcribing…"
  defp voice_label(:thinking), do: "thinking…"
  defp voice_label(:speaking), do: "speaking…"
  defp voice_label(_), do: "idle"

  defp voice_mic_label(:listening), do: "tap to record this turn"
  defp voice_mic_label(_), do: "mic unavailable"

  # the mic button itself sets the recording-vs-idle visual via a
  # data attribute toggled by the hook; styling here stays static.
  defp voice_mic_class(:listening),
    do: "btn btn-circle btn-lg bg-primary text-primary-content border-0 shadow-lg shadow-primary/30 hover:bg-primary/90 data-[recording=true]:bg-error data-[recording=true]:shadow-error/30 data-[recording=true]:animate-pulse"

  defp voice_mic_class(_),
    do: "btn btn-circle btn-lg bg-base-300/60 border-0 text-base-content/40 cursor-not-allowed"

  defp assistant_turns(messages) do
    messages
    |> Enum.with_index()
    |> Enum.filter(fn {msg, _idx} ->
      msg.role == "assistant" and is_binary(msg.content) and msg.content != ""
    end)
  end

  defp bubble_class(%{role: "user"}),
    do: "rounded-2xl rounded-tr-md bg-primary px-3.5 py-2 text-primary-content"

  defp bubble_class(_),
    do: "rounded-2xl rounded-tl-md bg-base-200/70 px-3.5 py-2 text-base-content"

  defp avatar_class(%{role: "user"}),
    do:
      "flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-primary/15 text-[10px] font-medium text-primary ring-1 ring-primary/20"

  defp avatar_class(_),
    do:
      "flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-base-300/80 text-[10px] font-medium text-base-content/60"

  defp avatar_label(%{role: "user"}), do: "you"
  defp avatar_label(_), do: "ai"

  defp cursor?(%{role: "assistant", streaming?: true}), do: true
  defp cursor?(_), do: false

  defp speakable?(%{role: "assistant", content: content} = msg)
       when is_binary(content) and content != "" do
    not Map.get(msg, :streaming?, false)
  end

  defp speakable?(_), do: false
end
