// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/phoenix_demo"
import topbar from "../vendor/topbar"

const ScrollBottom = {
  mounted() { this.scroll() },
  updated() { this.scroll() },
  scroll() { this.el.scrollTop = this.el.scrollHeight }
}

// enter submits the surrounding form, shift+enter inserts a newline.
// also auto-grows the textarea up to its css max-height. listens for
// a `set_input` push_event so the server can write into the textarea.
const EnterToSubmit = {
  mounted() {
    this.autosize()
    this.el.addEventListener("input", () => this.autosize())
    this.el.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
        e.preventDefault()
        this.el.form?.requestSubmit()
      }
    })
    this.handleEvent("set_input", ({value}) => {
      this.el.value = value
      this.autosize()
      this.el.focus()
    })
  },
  updated() { this.autosize() },
  autosize() {
    this.el.style.height = "auto"
    this.el.style.height = this.el.scrollHeight + "px"
  }
}

// server-pushed `play_audio` -> play an mp3 data url. one player at a
// time; pause any previous one. if the server sets `then` on the
// payload, we push that event back to the lv when playback ends —
// voice mode uses this to drive the next turn.
let currentAudio = null
window.addEventListener("phx:play_audio", (e) => {
  if (currentAudio) { try { currentAudio.pause() } catch (_) {} }
  const {src, then} = e.detail
  currentAudio = new Audio(src)
  if (then) {
    currentAudio.addEventListener("ended", () => {
      // bubble up via a custom window event; the voiceconvo hook
      // listens for this and pushes the named lv event so we don't
      // need to know which liveview is mounted.
      window.dispatchEvent(new CustomEvent("voice:audio_done", {detail: {then}}))
    })
  }
  currentAudio.play().catch(err => console.error("audio play failed", err))
})

// localStorage-backed memory across visits. on mount, hand the saved
// history to the server so it can seed `:messages`. on every
// `save_memory` event, mirror the latest list back to localStorage.
const MEMORY_KEY = "openrouter_demo:history:v1"

const MemoryStore = {
  mounted() {
    try {
      const raw = localStorage.getItem(MEMORY_KEY)
      if (raw) {
        const messages = JSON.parse(raw)
        if (Array.isArray(messages) && messages.length > 0) {
          this.pushEvent("restore_memory", {messages})
        }
      }
    } catch (err) {
      console.warn("[memory] could not restore:", err)
    }

    this.handleEvent("save_memory", ({messages}) => {
      try {
        localStorage.setItem(MEMORY_KEY, JSON.stringify(messages || []))
      } catch (err) {
        console.warn("[memory] could not save:", err)
      }
    })
  }
}

// turn-by-turn voice. owns nothing except the bridge from the audio
// player back to the lv (so when assistant tts finishes, the next
// turn's mic state can be enabled). also gracefully handles the
// `voice_session_stop` push event to release any held resources.
const VoiceConvo = {
  mounted() {
    this.onAudioDone = (e) => {
      const then = e.detail?.then
      if (then) this.pushEvent(then, {})
    }
    window.addEventListener("voice:audio_done", this.onAudioDone)

    this.handleEvent("voice_session_stop", () => {
      // nothing to clean up at the convo level — the mic hook handles
      // its own stream lifecycle. this exists for symmetry with the
      // server's state machine.
    })
  },
  destroyed() {
    window.removeEventListener("voice:audio_done", this.onAudioDone)
  }
}

// the big mic button in voice mode. one-tap to start recording, tap
// again to stop. ships the resulting blob to the server as
// `voice_audio`. the button's `data-state` attribute is set by the
// server so we know whether we're allowed to react to clicks at all
// (only :listening is recordable — :greeting / :thinking / :speaking
// are inert).
const VoiceMic = {
  mounted() {
    this.recording = false
    this.chunks = []
    this.stream = null
    this.recorder = null

    this.el.addEventListener("click", () => this.toggle())
  },

  destroyed() {
    this.cleanup()
  },

  toggle() {
    if (this.el.dataset.state !== "listening") return
    if (this.recording) {
      this.stop()
    } else {
      this.start()
    }
  },

  async start() {
    if (!navigator.mediaDevices?.getUserMedia) {
      alert("microphone is not available in this browser.")
      return
    }
    try {
      this.stream = await navigator.mediaDevices.getUserMedia({
        audio: {channelCount: 1, echoCancellation: true, noiseSuppression: true}
      })
    } catch (err) {
      console.error("[voice] mic permission denied", err)
      alert("microphone permission denied.")
      return
    }

    const mime = pickMime()
    this.recorder = new MediaRecorder(this.stream, mime ? {mimeType: mime} : undefined)
    this.chunks = []
    this.recorder.ondataavailable = (e) => { if (e.data?.size) this.chunks.push(e.data) }
    this.recorder.onstop = () => this.upload()
    this.recorder.start()
    this.recording = true
    this.setRecordingUI(true)
  },

  stop() {
    if (!this.recorder) return
    try { this.recorder.stop() } catch (_) {}
    this.recording = false
    this.setRecordingUI(false)
  },

  upload() {
    const type = this.recorder?.mimeType || "audio/webm"
    const blob = new Blob(this.chunks, {type})
    this.cleanup()
    if (!blob.size) return
    const reader = new FileReader()
    reader.onloadend = () => {
      const b64 = String(reader.result).split(",")[1] || ""
      this.pushEvent("voice_audio", {audio: b64, mime: type})
    }
    reader.readAsDataURL(blob)
  },

  cleanup() {
    this.stream?.getTracks().forEach(t => t.stop())
    this.stream = null
    this.recorder = null
    this.chunks = []
  },

  // toggle the inner svg via the data-recording attribute the
  // template's two child <span data-mic-idle/data-mic-recording> use.
  setRecordingUI(on) {
    this.el.dataset.recording = on ? "true" : "false"
    const idle = this.el.querySelector("[data-mic-idle]")
    const rec = this.el.querySelector("[data-mic-recording]")
    if (idle && rec) {
      idle.classList.toggle("hidden", on)
      rec.classList.toggle("hidden", !on)
    }
  }
}

// pick the most-supported audio container. firefox/chrome default to
// webm/opus; safari prefers mp4. all of these are accepted by the
// audio-input chat models openrouter routes to.
function pickMime() {
  const candidates = ["audio/webm;codecs=opus", "audio/webm", "audio/mp4", "audio/ogg;codecs=opus"]
  for (const m of candidates) {
    if (typeof MediaRecorder !== "undefined" && MediaRecorder.isTypeSupported(m)) return m
  }
  return ""
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ScrollBottom, EnterToSubmit, MemoryStore, VoiceConvo, VoiceMic},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// dev quality-of-life: stream server logs to console + alt-click to
// jump to source.
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    reloader.enableServerLogs()

    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault(); e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault(); e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
