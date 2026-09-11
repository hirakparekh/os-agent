// Mic recording → Sarvam transcript, and assistant text → Sarvam speech, for the chat page.
// All network calls go through api.ts (console/backend/voice.py proxies to Sarvam).
import { useCallback, useEffect, useRef, useState } from "react"

import { errorDetail, getVoiceOptions, synthesizeSpeech, transcribeAudio, type VoiceOptions } from "@/api"

const PREFS_KEY = "agent-os:voice-prefs"
// Sarvam's synchronous speech-to-text endpoint is meant for short clips; a chat question fits
// comfortably, and a hard stop avoids an accidental open mic uploading minutes of audio.
export const MAX_RECORDING_MS = 30_000

const MIME_CANDIDATES = ["audio/webm;codecs=opus", "audio/webm", "audio/mp4", "audio/ogg;codecs=opus"]

const NOT_CONFIGURED =
  "Voice isn't set up yet — add SARVAM_API_KEY to the console backend's .env and restart it."

export const LANGUAGE_NAMES: Record<string, string> = {
  "en-IN": "English",
  "hi-IN": "Hindi",
  "bn-IN": "Bengali",
  "gu-IN": "Gujarati",
  "kn-IN": "Kannada",
  "ml-IN": "Malayalam",
  "mr-IN": "Marathi",
  "od-IN": "Odia",
  "pa-IN": "Punjabi",
  "ta-IN": "Tamil",
  "te-IN": "Telugu",
}

export interface VoicePrefs {
  language: string
  speaker: string
  /** Read each new answer aloud as soon as it arrives. */
  autoSpeak: boolean
}

export type RecordingState = "idle" | "recording" | "transcribing"

type MessageId = number | string

function loadPrefs(): Partial<VoicePrefs> {
  try {
    const raw = localStorage.getItem(PREFS_KEY)
    return raw ? (JSON.parse(raw) as Partial<VoicePrefs>) : {}
  } catch {
    return {}
  }
}

function savePrefs(prefs: VoicePrefs) {
  try {
    localStorage.setItem(PREFS_KEY, JSON.stringify(prefs))
  } catch {
    // Storage disabled — prefs just reset next visit.
  }
}

function pickMimeType(): string | undefined {
  if (typeof MediaRecorder === "undefined") return undefined
  return MIME_CANDIDATES.find((t) => MediaRecorder.isTypeSupported(t))
}

export function useVoice({ onTranscript }: { onTranscript: (text: string) => void }) {
  const [options, setOptions] = useState<VoiceOptions | null>(null)
  const [prefs, setPrefsState] = useState<VoicePrefs>(() => ({
    language: "en-IN",
    speaker: "shubh",
    autoSpeak: false,
    ...loadPrefs(),
  }))
  const [recording, setRecording] = useState<RecordingState>("idle")
  const [elapsedMs, setElapsedMs] = useState(0)
  const [playingId, setPlayingId] = useState<MessageId | null>(null)
  const [loadingId, setLoadingId] = useState<MessageId | null>(null)
  const [error, setError] = useState<string | null>(null)

  // Refs, not state, wherever a callback can outlive the render that created it (the recorder's
  // onstop, an awaited speech fetch, Chat's handleSend awaiting an LLM answer).
  const prefsRef = useRef(prefs)
  const configuredRef = useRef(false)
  const onTranscriptRef = useRef(onTranscript)
  onTranscriptRef.current = onTranscript
  const recorderRef = useRef<MediaRecorder | null>(null)
  const streamRef = useRef<MediaStream | null>(null)
  const chunksRef = useRef<Blob[]>([])
  const discardRef = useRef(false)
  const tickRef = useRef<number | undefined>(undefined)
  const capRef = useRef<number | undefined>(undefined)
  const audioRef = useRef<HTMLAudioElement | null>(null)
  const playingRef = useRef<MessageId | null>(null)
  // Bumped on every new speak/stop so a slow synthesis for an older click can't start playing
  // over whatever the user asked for since.
  const speakSeq = useRef(0)
  // Object URLs per message+voice, so replaying an answer doesn't re-bill Sarvam.
  const audioCache = useRef(new Map<string, string>())

  useEffect(() => {
    let cancelled = false
    getVoiceOptions()
      .then((opts) => {
        if (cancelled) return
        configuredRef.current = opts.configured
        setOptions(opts)
        setPrefsState((p) => {
          const next = {
            ...p,
            language: opts.languages.includes(p.language) ? p.language : opts.default_language,
            speaker: opts.speakers.includes(p.speaker) ? p.speaker : opts.default_speaker,
          }
          prefsRef.current = next
          return next
        })
      })
      .catch(() => {
        // Leave voice unconfigured; the mic/speaker buttons explain why when clicked.
      })
    return () => {
      cancelled = true
    }
  }, [])

  useEffect(() => {
    const cache = audioCache.current
    return () => {
      discardRef.current = true
      if (recorderRef.current && recorderRef.current.state !== "inactive") recorderRef.current.stop()
      streamRef.current?.getTracks().forEach((t) => t.stop())
      window.clearInterval(tickRef.current)
      window.clearTimeout(capRef.current)
      audioRef.current?.pause()
      cache.forEach((url) => URL.revokeObjectURL(url))
      cache.clear()
    }
  }, [])

  function setPrefs(patch: Partial<VoicePrefs>) {
    setPrefsState((p) => {
      const next = { ...p, ...patch }
      prefsRef.current = next
      savePrefs(next)
      return next
    })
  }

  function releaseMic() {
    streamRef.current?.getTracks().forEach((t) => t.stop())
    streamRef.current = null
    window.clearInterval(tickRef.current)
    window.clearTimeout(capRef.current)
  }

  // Stable identity (refs + setters only), so pages can list it as an effect dependency.
  const stopPlayback = useCallback(() => {
    speakSeq.current++
    audioRef.current?.pause()
    audioRef.current = null
    playingRef.current = null
    setPlayingId(null)
    setLoadingId(null)
  }, [])

  function stopRecording() {
    const recorder = recorderRef.current
    recorderRef.current = null
    if (recorder && recorder.state !== "inactive") recorder.stop()
  }

  function cancelRecording() {
    discardRef.current = true
    stopRecording()
  }

  async function startRecording() {
    setError(null)
    if (!configuredRef.current) {
      setError(NOT_CONFIGURED)
      return
    }
    if (!navigator.mediaDevices?.getUserMedia || typeof MediaRecorder === "undefined") {
      setError("This browser can't record audio.")
      return
    }
    let stream: MediaStream
    try {
      stream = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: true, noiseSuppression: true },
      })
    } catch {
      setError("Microphone access was blocked — allow it in the browser's site settings.")
      return
    }
    // Don't let the assistant's own voice end up in the recording.
    stopPlayback()

    const mimeType = pickMimeType()
    const recorder = new MediaRecorder(stream, mimeType ? { mimeType } : undefined)
    chunksRef.current = []
    discardRef.current = false
    recorder.ondataavailable = (e) => {
      if (e.data.size > 0) chunksRef.current.push(e.data)
    }
    recorder.onstop = async () => {
      releaseMic()
      const blob = new Blob(chunksRef.current, { type: recorder.mimeType || mimeType || "audio/webm" })
      chunksRef.current = []
      if (discardRef.current || blob.size === 0) {
        setRecording("idle")
        return
      }
      setRecording("transcribing")
      try {
        const { transcript } = await transcribeAudio(blob, prefsRef.current.language)
        if (transcript) onTranscriptRef.current(transcript)
        else setError("Didn't catch that — try again a little closer to the mic.")
      } catch (err) {
        setError(errorDetail(err))
      } finally {
        setRecording("idle")
      }
    }

    recorderRef.current = recorder
    streamRef.current = stream
    recorder.start()
    setRecording("recording")
    setElapsedMs(0)
    const startedAt = Date.now()
    tickRef.current = window.setInterval(() => setElapsedMs(Date.now() - startedAt), 250)
    capRef.current = window.setTimeout(stopRecording, MAX_RECORDING_MS)
  }

  async function speak(id: MessageId, text: string) {
    setError(null)
    if (!configuredRef.current) {
      setError(NOT_CONFIGURED)
      return
    }
    if (playingRef.current === id) {
      stopPlayback()
      return
    }
    stopPlayback()
    const seq = speakSeq.current
    const { language, speaker } = prefsRef.current
    const cacheKey = `${id}|${language}|${speaker}`

    let url = audioCache.current.get(cacheKey)
    if (!url) {
      setLoadingId(id)
      try {
        const blob = await synthesizeSpeech(text, language, speaker)
        url = URL.createObjectURL(blob)
        audioCache.current.set(cacheKey, url)
      } catch (err) {
        if (seq === speakSeq.current) setError(errorDetail(err))
        return
      } finally {
        if (seq === speakSeq.current) setLoadingId(null)
      }
    }
    if (seq !== speakSeq.current) return

    const audio = new Audio(url)
    audioRef.current = audio
    playingRef.current = id
    setPlayingId(id)
    audio.onended = () => {
      if (audioRef.current !== audio) return
      audioRef.current = null
      playingRef.current = null
      setPlayingId(null)
    }
    try {
      await audio.play()
    } catch {
      if (audioRef.current === audio) stopPlayback()
      setError("The browser blocked audio playback — click the speaker icon to play it.")
    }
  }

  function autoSpeak(id: MessageId, text: string) {
    if (prefsRef.current.autoSpeak && configuredRef.current) void speak(id, text)
  }

  return {
    options,
    configured: options?.configured ?? false,
    prefs,
    setPrefs,
    recording,
    elapsedMs,
    startRecording,
    stopRecording,
    cancelRecording,
    playingId,
    loadingId,
    speak,
    autoSpeak,
    stopPlayback,
    error,
    clearError: () => setError(null),
  }
}

export type VoiceControls = ReturnType<typeof useVoice>
