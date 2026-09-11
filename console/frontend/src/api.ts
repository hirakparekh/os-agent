// The ONLY module that talks to the backend (ADR-0002). No third-party API calls here.
import { type AccessRole, clearToken, getToken } from "@/auth"

const BASE_URL: string = import.meta.env.VITE_API_BASE_URL ?? "http://localhost:8000"

// ---------------------------------------------------------------------------
// DEMO MODE — works entirely in-browser with no backend, and has no seeded accounts.
// Set VITE_API_BASE_URL to a real server to disable this.
// ---------------------------------------------------------------------------
const DEMO_MODE = !import.meta.env.VITE_API_BASE_URL

function delay(ms = 400) { return new Promise((r) => setTimeout(r, ms)) }

export type IntegrationStatus = "configured" | "not_configured"

export interface IntegrationHealth {
  name: string
  status: IntegrationStatus
}

export interface HealthReport {
  ok: boolean
  integrations: IntegrationHealth[]
}

export interface UserMe {
  id: number
  email: string
  role: AccessRole
}

// Parsed résumé — mirrors the talent-radar schema from tools/resume/parser.py
export interface RadarAxis {
  score: number
  evidence: string | null
}

export interface ResumeData {
  schema_version: string
  parse_confidence: number
  name: string | null
  email: string | null
  headline: string | null
  summary: string | null
  total_years_experience: number | null
  seniority: string | null
  skills: string[]
  strengths: string[]
  domains: string[]
  roles: Array<{
    company: string | null
    title: string | null
    start: string | null
    end: string | null
    months: number | null
    highlights: string[]
  }>
  education: Array<{
    degree: string | null
    field: string | null
    institution: string | null
    year: number | null
  }>
  certifications: string[]
  achievements: string[]
  radar: Record<string, RadarAxis>
  flags: string[]
}

export class ApiError extends Error {
  constructor(
    public status: number,
    message: string,
  ) {
    super(message)
  }
}

async function authedFetch(path: string, init: RequestInit = {}): Promise<Response> {
  const headers = new Headers(init.headers)
  const token = getToken()
  if (token) headers.set("Authorization", `Bearer ${token}`)

  const res = await fetch(`${BASE_URL}${path}`, { ...init, headers })
  if (res.status === 401) {
    clearToken()
    throw new ApiError(401, "Not authenticated")
  }
  if (!res.ok) {
    const detail = await res.text()
    throw new ApiError(res.status, detail || res.statusText)
  }
  return res
}

async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers = new Headers(init.headers)
  headers.set("Content-Type", "application/json")
  const res = await authedFetch(path, { ...init, headers })
  return (await res.json()) as T
}

/** FastAPI errors arrive as `{"detail": "..."}` text in ApiError.message — unwrap for display. */
export function errorDetail(err: unknown): string {
  if (!(err instanceof Error)) return "Something went wrong."
  try {
    const parsed = JSON.parse(err.message) as { detail?: unknown }
    if (typeof parsed.detail === "string") return parsed.detail
  } catch {
    // Not JSON — fall through to the raw message.
  }
  return err.message
}

export async function login(email: string, password: string): Promise<string> {
  if (DEMO_MODE) {
    await delay()
    // No seeded accounts in demo mode — point VITE_API_BASE_URL at a real backend to sign in.
    throw new ApiError(401, "Sign-in needs a connected backend (set VITE_API_BASE_URL).")
  }
  const data = await request<{ token: string }>("/auth/login", {
    method: "POST",
    body: JSON.stringify({ email, password }),
  })
  return data.token
}

export async function getMe(): Promise<UserMe> {
  if (DEMO_MODE) {
    await delay(200)
    throw new ApiError(401, "Not authenticated")
  }
  return request<UserMe>("/auth/me")
}

export async function getHealth(): Promise<HealthReport> {
  if (DEMO_MODE) {
    await delay(300)
    // Nothing is actually connected until you set the real tokens (see SETUP.md).
    return {
      ok: false,
      integrations: [
        { name: "slack",   status: "not_configured" },
        { name: "fathom",  status: "not_configured" },
      ],
    }
  }
  return request<HealthReport>("/health")
}

/**
 * Fetch the parsed résumé for an employee.
 * Developers can only fetch their own (backend enforces with 403).
 */
export async function getResume(email: string): Promise<ResumeData> {
  if (DEMO_MODE) {
    await delay(400)
    throw new ApiError(404, `No résumé on file for ${email} in demo mode.`)
  }
  return request<ResumeData>(`/resume?email=${encodeURIComponent(email)}`)
}

// ===========================================================================
// Applications (integration setup) — the "Applications" page (formerly "Health")
//
// ⚠️ BACKEND DEV: the connect/disconnect endpoints below DO NOT EXIST YET.
// Today the backend only exposes GET /health (read-only status of the 3 core apps).
// To let HR *set up* apps from the UI, please implement:
//
//   GET  /applications
//     → Application[]  — the full catalog (core + available) with live `connected` state.
//       v1 may derive the 3 core apps from the existing /health check. Until this exists
//       the frontend falls back to the hardcoded CORE_APPS / AVAILABLE_APPS below.
//
//   POST /applications/{id}/connect    body: { credential: string }
//     → For a "token" app: validate the token, STORE IT SECURELY server-side
//       (env / secret store — NEVER return it to the browser), mark the app connected.
//       For an "oauth" app (Slack, Google): ignore `credential`, instead return
//       { authUrl } and let the browser redirect to begin the OAuth flow; the callback
//       endpoint stores the resulting token. Return 200 + the updated Application.
//
//   POST /applications/{id}/disconnect
//     → remove the stored credential, mark disconnected. Return 200.
//
// SECURITY: credentials only ever travel browser → backend (HTTPS), are stored as
// secrets, and are never sent back down. This honors ADR-0002 (no third-party SDKs/
// tokens in the browser) — the frontend only ever talks to OUR backend.
// ===========================================================================

export type AppConnectKind = "token" | "oauth"

export interface Application {
  id: string // stable key: "clickup", "slack", "fathom", "google_calendar", …
  name: string // display name
  description: string // one-liner shown on the card
  connected: boolean
  kind: AppConnectKind // "token" → show a credential field; "oauth" → redirect flow
  credentialLabel?: string // e.g. "API token" (only for kind === "token")
}

// Integrations tracked by the ops backend. Live connected-status comes from getHealth();
// this is just the display metadata. Slack is a real integration: POST /applications/slack/
// connect validates the bot token against Slack's own auth.test API and stores it server-side
// (console/backend/applications.py) — nothing here is a placeholder.
export const CORE_APPS: Record<string, Omit<Application, "id" | "connected">> = {
  slack: { name: "Slack", description: "Post and read messages in your workspace.", kind: "token", credentialLabel: "Bot token (xoxb-...)" },
}

// Gmail and Google Calendar are OAuth flows hosted by the brain service (their live connected
// state comes from brainApi.getMailStatus() / getCalendarStatus(), not from getHealth()) —
// `connected: false` here is just the fallback before that status loads. Both are real: the
// "Connect" button opens the actual Google OAuth consent screen (see brain/emailtool.py and
// brain/calendar_tool.py).
export const GMAIL_APP: Omit<Application, "connected"> = {
  id: "gmail",
  name: "Gmail",
  description: "Reads your unread mail so you can ask about it. See the Chat tab.",
  kind: "oauth",
}

export const GOOGLE_CALENDAR_APP: Omit<Application, "connected"> = {
  id: "google_calendar",
  name: "Google Calendar",
  description: "See your real upcoming events when you ask the chat about your schedule.",
  kind: "oauth",
}

// Additional apps you can connect via the generic token flow (POST /applications/{id}/connect).
export const AVAILABLE_APPS: Application[] = []

export function connectApp(id: string, credential: string): Promise<{ authUrl?: string }> {
  return request<{ authUrl?: string }>(`/applications/${id}/connect`, {
    method: "POST",
    body: JSON.stringify({ credential }),
  })
}

export function disconnectApp(id: string): Promise<void> {
  return request<void>(`/applications/${id}/disconnect`, { method: "POST" })
}

// ===========================================================================
// Chat — persisted mail-chat sessions (console/backend/chat.py). Lives here, not in
// lib/brainApi.ts, because console/backend owns session/message storage and ownership
// checks; it proxies the actual Q&A to the brain service server-side (see chat.py).
// ===========================================================================

export interface ChatSession {
  id: number
  title: string | null
  created_at: string
  updated_at: string
}

export interface ChatMessage {
  id: number
  role: "user" | "assistant"
  content: string
  created_at: string
}

export interface ChatSessionWithMessages extends ChatSession {
  messages: ChatMessage[]
}

export interface ChatProfileDetail {
  key: string
  value: string
}

export function listChatSessions(): Promise<ChatSession[]> {
  return request<ChatSession[]>("/chat/sessions")
}

export function createChatSession(): Promise<ChatSession> {
  return request<ChatSession>("/chat/sessions", { method: "POST" })
}

export function getChatSession(id: number): Promise<ChatSessionWithMessages> {
  return request<ChatSessionWithMessages>(`/chat/sessions/${id}`)
}

export function renameChatSession(id: number, title: string): Promise<ChatSession> {
  return request<ChatSession>(`/chat/sessions/${id}`, {
    method: "PATCH",
    body: JSON.stringify({ title }),
  })
}

export function deleteChatSession(id: number): Promise<void> {
  return request<void>(`/chat/sessions/${id}`, { method: "DELETE" })
}

export function postChatMessage(
  sessionId: number,
  question: string,
  profileDetails: ChatProfileDetail[],
): Promise<ChatMessage> {
  return request<ChatMessage>(`/chat/sessions/${sessionId}/messages`, {
    method: "POST",
    body: JSON.stringify({ question, profile_details: profileDetails }),
  })
}

// ===========================================================================
// Voice — Sarvam AI speech-to-text / text-to-speech, proxied by console/backend/voice.py so
// the Sarvam key never reaches the browser.
// ===========================================================================

export interface VoiceOptions {
  configured: boolean
  languages: string[]
  speakers: string[]
  default_language: string
  default_speaker: string
}

export async function getVoiceOptions(): Promise<VoiceOptions> {
  if (DEMO_MODE) {
    return {
      configured: false,
      languages: ["en-IN"],
      speakers: ["shubh"],
      default_language: "en-IN",
      default_speaker: "shubh",
    }
  }
  return request<VoiceOptions>("/voice/options")
}

export async function transcribeAudio(
  audio: Blob,
  languageCode: string,
): Promise<{ transcript: string; language_code: string | null }> {
  const ext = audio.type.includes("mp4") ? "m4a" : audio.type.includes("ogg") ? "ogg" : "webm"
  const form = new FormData()
  form.append("file", audio, `recording.${ext}`)
  form.append("language_code", languageCode)
  const res = await authedFetch("/voice/transcribe", { method: "POST", body: form })
  return (await res.json()) as { transcript: string; language_code: string | null }
}

export async function synthesizeSpeech(
  text: string,
  languageCode: string,
  speaker: string,
): Promise<Blob> {
  const res = await authedFetch("/voice/speak", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ text, language_code: languageCode, speaker }),
  })
  return res.blob()
}


