// Composer popover for voice preferences: language (used for both listening and speaking),
// which Sarvam voice reads answers, and whether new answers are read aloud automatically.
import { Loader2, Play, SlidersHorizontal, Square } from "lucide-react"
import { useEffect, useRef, useState } from "react"

import { LANGUAGE_NAMES, type VoiceControls } from "@/lib/useVoice"

const PREVIEW_ID = "voice-preview"
const PREVIEW_TEXT = "Hi! This is how I'll sound when I read your answers aloud."

function capitalize(s: string): string {
  return s.charAt(0).toUpperCase() + s.slice(1)
}

export function VoiceSettings({ voice }: { voice: VoiceControls }) {
  const [open, setOpen] = useState(false)
  const rootRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) return
    function onPointerDown(e: PointerEvent) {
      if (!rootRef.current?.contains(e.target as Node)) setOpen(false)
    }
    function onKeyDown(e: KeyboardEvent) {
      if (e.key === "Escape") setOpen(false)
    }
    document.addEventListener("pointerdown", onPointerDown)
    document.addEventListener("keydown", onKeyDown)
    return () => {
      document.removeEventListener("pointerdown", onPointerDown)
      document.removeEventListener("keydown", onKeyDown)
    }
  }, [open])

  const languages = voice.options?.languages ?? [voice.prefs.language]
  const speakers = voice.options?.speakers ?? [voice.prefs.speaker]
  const previewing = voice.playingId === PREVIEW_ID
  const previewLoading = voice.loadingId === PREVIEW_ID

  return (
    <div ref={rootRef} className="relative">
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        aria-label="Voice settings"
        aria-expanded={open}
        className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
      >
        <SlidersHorizontal className="h-4 w-4" />
      </button>

      {open && (
        <div
          role="dialog"
          aria-label="Voice settings"
          className="absolute bottom-full right-0 z-20 mb-2 w-72 rounded-2xl border border-border bg-card p-4 text-sm shadow-lg"
        >
          <p className="mb-3 font-medium text-foreground">Voice</p>
          {!voice.configured && (
            <p className="mb-3 rounded-lg bg-caution px-3 py-2 text-xs text-caution-foreground">
              Not configured — add <code>SARVAM_API_KEY</code> to the backend's <code>.env</code>.
            </p>
          )}

          <label className="mb-3 block">
            <span className="mb-1 block text-xs text-muted-foreground">Language</span>
            <select
              value={voice.prefs.language}
              onChange={(e) => voice.setPrefs({ language: e.target.value })}
              className="w-full rounded-lg border border-input bg-background px-2 py-1.5 outline-none focus-visible:ring-2 focus-visible:ring-ring"
            >
              {languages.map((code) => (
                <option key={code} value={code}>
                  {LANGUAGE_NAMES[code] ?? code}
                </option>
              ))}
            </select>
          </label>

          <label className="mb-3 block">
            <span className="mb-1 block text-xs text-muted-foreground">Reading voice</span>
            <div className="flex items-center gap-2">
              <select
                value={voice.prefs.speaker}
                onChange={(e) => voice.setPrefs({ speaker: e.target.value })}
                className="min-w-0 flex-1 rounded-lg border border-input bg-background px-2 py-1.5 outline-none focus-visible:ring-2 focus-visible:ring-ring"
              >
                {speakers.map((s) => (
                  <option key={s} value={s}>
                    {capitalize(s)}
                  </option>
                ))}
              </select>
              <button
                type="button"
                onClick={() => voice.speak(PREVIEW_ID, PREVIEW_TEXT)}
                aria-label={previewing ? "Stop preview" : "Preview voice"}
                className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg border border-border text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
              >
                {previewLoading ? (
                  <Loader2 className="h-3.5 w-3.5 animate-spin" />
                ) : previewing ? (
                  <Square className="h-3.5 w-3.5" />
                ) : (
                  <Play className="h-3.5 w-3.5" />
                )}
              </button>
            </div>
          </label>

          <label className="flex cursor-pointer items-center justify-between gap-3">
            <span className="text-foreground">Read answers aloud</span>
            <input
              type="checkbox"
              checked={voice.prefs.autoSpeak}
              onChange={(e) => voice.setPrefs({ autoSpeak: e.target.checked })}
              className="h-4 w-4 accent-primary"
            />
          </label>
        </div>
      )}
    </div>
  )
}
