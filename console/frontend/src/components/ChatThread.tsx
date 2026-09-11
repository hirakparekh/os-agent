// The message list + composer, styled after Claude's chat screen: plain text for assistant
// messages, a rounded bubble for user messages, a pill-shaped composer pinned to the bottom.
// Extracted from the old MailChat.tsx so both a full-page chat (pages/Chat.tsx) and any future
// smaller usage can share the same rendering without duplicating this markup.
import { ArrowUp, Loader2, Mic, Square, Volume2, X } from "lucide-react"
import { useEffect, useRef } from "react"

import { VoiceSettings } from "@/components/VoiceSettings"
import { MAX_RECORDING_MS, type VoiceControls } from "@/lib/useVoice"

export interface ThreadMessage {
  id: number | string
  role: "user" | "assistant"
  content: string
}

interface ChatThreadProps {
  messages: ThreadMessage[]
  pending: boolean
  input: string
  onInputChange: (value: string) => void
  onSend: () => void
  emptyStatePrompt: string
  disabled?: boolean
  /** History is being fetched. Shown inside the transcript so the composer stays mounted. */
  loading?: boolean
  /** Mic input + read-aloud. Omit to render a text-only thread. */
  voice?: VoiceControls
}

function clock(ms: number): string {
  const s = Math.floor(ms / 1000)
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`
}

export function ChatThread({
  messages,
  pending,
  input,
  onInputChange,
  onSend,
  emptyStatePrompt,
  disabled,
  loading,
  voice,
}: ChatThreadProps) {
  const scrollRef = useRef<HTMLDivElement>(null)
  const textareaRef = useRef<HTMLTextAreaElement>(null)
  const prevRecording = useRef(voice?.recording)

  useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight, behavior: "smooth" })
  }, [messages, pending])

  // Hand focus back to the composer once a transcript lands, so Enter sends it.
  useEffect(() => {
    if (prevRecording.current === "transcribing" && voice?.recording === "idle") {
      textareaRef.current?.focus()
    }
    prevRecording.current = voice?.recording
  }, [voice?.recording])

  const recording = voice?.recording === "recording"
  const transcribing = voice?.recording === "transcribing"

  return (
    <div className="flex h-full w-full flex-col">
      <div ref={scrollRef} data-testid="chat-thread" className="flex-1 overflow-y-auto px-5 py-6">
        {loading ? (
          <div className="flex h-full items-center justify-center">
            <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
          </div>
        ) : messages.length === 0 ? (
          <div className="flex h-full flex-col items-center justify-center gap-1 text-center">
            <p className="text-sm text-muted-foreground">{emptyStatePrompt}</p>
          </div>
        ) : (
          <div className="mx-auto flex w-full max-w-2xl flex-col gap-5">
            {messages.map((m) => (
              <div key={m.id} className={m.role === "user" ? "flex justify-end" : "flex justify-start"}>
                <div
                  className={
                    m.role === "user"
                      ? "max-w-[85%] rounded-2xl bg-secondary px-4 py-2 text-sm text-secondary-foreground"
                      : "max-w-[85%] whitespace-pre-wrap text-sm leading-relaxed text-foreground"
                  }
                >
                  {m.content}
                  {/* Only persisted answers (numeric ids) — not local error placeholders. */}
                  {voice && m.role === "assistant" && typeof m.id === "number" && (
                    <div className="mt-1.5">
                      <button
                        type="button"
                        onClick={() => voice.speak(m.id, m.content)}
                        aria-label={voice.playingId === m.id ? "Stop reading" : "Read aloud"}
                        className={[
                          "flex h-7 items-center gap-1.5 rounded-full px-2 text-xs transition-colors",
                          voice.playingId === m.id
                            ? "bg-accent text-foreground"
                            : "text-muted-foreground hover:bg-accent hover:text-foreground",
                        ].join(" ")}
                      >
                        {voice.loadingId === m.id ? (
                          <Loader2 className="h-3.5 w-3.5 animate-spin" />
                        ) : voice.playingId === m.id ? (
                          <Square className="h-3 w-3 fill-current" />
                        ) : (
                          <Volume2 className="h-3.5 w-3.5" />
                        )}
                        {voice.playingId === m.id ? "Stop" : voice.loadingId === m.id ? "Preparing…" : "Listen"}
                      </button>
                    </div>
                  )}
                </div>
              </div>
            ))}
            {pending && (
              <div className="flex justify-start">
                <div className="max-w-[85%] text-sm leading-relaxed text-muted-foreground">
                  Thinking…
                </div>
              </div>
            )}
          </div>
        )}
      </div>

      <div className="relative px-5 pb-5 pt-2">
        {voice?.error && (
          <div className="mx-auto mb-2 flex w-full max-w-2xl items-start justify-between gap-3 rounded-xl bg-destructive/10 px-3 py-2 text-xs text-destructive">
            <span>{voice.error}</span>
            <button type="button" onClick={voice.clearError} aria-label="Dismiss" className="shrink-0">
              <X className="h-3.5 w-3.5" />
            </button>
          </div>
        )}
        <div className="mx-auto flex w-full max-w-2xl items-end gap-2 rounded-3xl border border-input bg-background px-3 py-2 shadow-sm focus-within:ring-2 focus-within:ring-ring">
          {recording && voice ? (
            <div className="flex min-h-[36px] flex-1 items-center gap-2 px-2 text-sm" aria-live="polite">
              <span className="relative flex h-2.5 w-2.5">
                <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-destructive opacity-60" />
                <span className="relative inline-flex h-2.5 w-2.5 rounded-full bg-destructive" />
              </span>
              <span className="text-foreground">Listening…</span>
              <span className="tabular-nums text-muted-foreground">
                {clock(voice.elapsedMs)} / {clock(MAX_RECORDING_MS)}
              </span>
              <button
                type="button"
                onClick={voice.cancelRecording}
                className="ml-auto text-xs text-muted-foreground underline-offset-4 hover:text-foreground hover:underline"
              >
                Cancel
              </button>
            </div>
          ) : (
            <textarea
              ref={textareaRef}
              value={input}
              onChange={(e) => onInputChange(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && !e.shiftKey) {
                  e.preventDefault()
                  onSend()
                }
              }}
              placeholder={transcribing ? "Transcribing…" : "Ask a question…"}
              rows={1}
              disabled={disabled || transcribing}
              className="max-h-32 flex-1 resize-none bg-transparent px-2 py-1.5 text-sm outline-none placeholder:text-muted-foreground disabled:opacity-50"
            />
          )}
          {voice && (
            <>
              {!recording && <VoiceSettings voice={voice} />}
              <button
                type="button"
                onClick={() => (recording ? voice.stopRecording() : voice.startRecording())}
                disabled={disabled || transcribing}
                aria-label={recording ? "Stop recording" : "Speak your question"}
                className={[
                  "flex h-8 w-8 shrink-0 items-center justify-center rounded-full transition-colors disabled:opacity-40",
                  recording
                    ? "bg-destructive text-destructive-foreground"
                    : "text-muted-foreground hover:bg-accent hover:text-foreground",
                ].join(" ")}
              >
                {transcribing ? (
                  <Loader2 className="h-4 w-4 animate-spin" />
                ) : recording ? (
                  <Square className="h-3.5 w-3.5 fill-current" />
                ) : (
                  <Mic className="h-4 w-4" />
                )}
              </button>
            </>
          )}
          <button
            type="button"
            // Wrapped, not passed directly: onClick would hand the MouseEvent to onSend's
            // first parameter, which the caller uses for retry text.
            onClick={() => onSend()}
            disabled={disabled || !input.trim() || pending || recording || transcribing}
            aria-label="Send"
            className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-primary text-primary-foreground transition-opacity disabled:opacity-40"
          >
            <ArrowUp className="h-4 w-4" />
          </button>
        </div>
      </div>
    </div>
  )
}
