// Talks to brain/viz_server.py (the mail knowledge-tree service, port 8080) — a separate
// backend from console/backend (port 8000, see src/api.ts). Kept in its own module since it's
// a different service with its own base URL, not part of the ops-console API surface.
//
// Both services verify the same JWT (issued only by console/backend's /auth/login — see
// security/tokens.py), so the token from src/auth.ts is attached here too.
import { clearToken, getToken } from "@/auth"

const BASE_URL: string = import.meta.env.VITE_BRAIN_API_BASE_URL ?? "http://localhost:8080"

export class BrainApiError extends Error {
  constructor(
    public status: number,
    message: string,
  ) {
    super(message)
  }
}

export interface MailClassification {
  category: string
  confidence: "high" | "medium" | "low"
  llm_category?: string | null
  keyword_category?: string | null
  scores?: Record<string, number>
  corrected_by_user?: boolean
  auto_category?: string | null
}

export interface MailNode {
  id: string
  name: string
  type: "root" | "mail_category" | "mail_topic" | "mail_thread"
  summary?: string | null
  body?: string | null
  source_uids?: string[]
  // True when the classifier wasn't sure where this belonged — surfaced in the UI so a wrong
  // filing is findable instead of silently wrong.
  needs_review?: boolean
  classification?: MailClassification | null
  children?: MailNode[]
}

export interface MailReclassifyResult {
  thread_id: string
  category: string
  topic: string
  topic_id: string
  pruned: string[]
}

export interface MailReloadResult {
  processed: number
  results: Array<Record<string, unknown>>
}

async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers = new Headers(init.headers)
  headers.set("Content-Type", "application/json")
  const token = getToken()
  if (token) headers.set("Authorization", `Bearer ${token}`)

  const res = await fetch(`${BASE_URL}${path}`, { ...init, headers })
  if (res.status === 401) {
    clearToken()
    throw new BrainApiError(401, "Not authenticated")
  }
  if (!res.ok) {
    const detail = await res.text()
    throw new BrainApiError(res.status, detail || res.statusText)
  }
  return (await res.json()) as T
}

export function getMailTree(): Promise<MailNode> {
  return request<MailNode>("/api/mail_tree")
}

export function reloadMail(sinceMinutes: number): Promise<MailReloadResult> {
  return request<MailReloadResult>("/api/mail/reload", {
    method: "POST",
    body: JSON.stringify({ since_minutes: sinceMinutes }),
  })
}

export interface CreatedCalendarEvent {
  event_id: string
  title: string
  start: string
  end: string
  thread_id: string
}

export interface MailProgress {
  stage: "connecting" | "fetched" | "ingesting" | "ingested" | "done" | "failed"
  total?: number
  done?: number
  subject?: string
  category?: string
  topic?: string
  processed?: number
  error?: string
  /** Set on an "ingested" event when this email described a dated event and Google Calendar
   * was connected — the mail pipeline already created it; see brain/mail_ingest.py. */
  calendar_event?: CreatedCalendarEvent | null
}

/**
 * Read an NDJSON progress stream from `path`, calling `onProgress` per line.
 *
 * Shared by mail and Slack sync — both endpoints emit the same {stage, done, total, ...}
 * shape (see brain/mail_ingest.py's run_iter and brain/slack_ingest.py's run_iter). Uses
 * fetch (not EventSource) because EventSource cannot send an Authorization header.
 */
async function streamNdjson(path: string, body: unknown, onProgress: (event: MailProgress) => void): Promise<MailProgress[]> {
  const headers = new Headers({ "Content-Type": "application/json" })
  const token = getToken()
  if (token) headers.set("Authorization", `Bearer ${token}`)

  const res = await fetch(`${BASE_URL}${path}`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  })
  if (res.status === 401) {
    clearToken()
    throw new BrainApiError(401, "Not authenticated")
  }
  if (!res.ok || !res.body) {
    throw new BrainApiError(res.status, (await res.text()) || res.statusText)
  }

  const reader = res.body.getReader()
  const decoder = new TextDecoder()
  const seen: MailProgress[] = []
  let buffer = ""

  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    buffer += decoder.decode(value, { stream: true })
    // A chunk can split mid-line, so keep the trailing partial for the next read.
    const lines = buffer.split("\n")
    buffer = lines.pop() ?? ""
    for (const line of lines) {
      if (!line.trim()) continue
      const event = JSON.parse(line) as MailProgress
      seen.push(event)
      onProgress(event)
    }
  }
  return seen
}

/** Ingest mail, reporting progress as it happens — see streamNdjson. */
export function reloadMailStream(
  sinceMinutes: number,
  onProgress: (event: MailProgress) => void,
): Promise<MailProgress[]> {
  return streamNdjson("/api/mail/reload/stream", { since_minutes: sinceMinutes }, onProgress)
}

/** Ingest new Slack messages from the configured channel, reporting progress as it happens. */
export function reloadSlackStream(onProgress: (event: MailProgress) => void): Promise<MailProgress[]> {
  return streamNdjson("/api/slack/reload/stream", {}, onProgress)
}

export interface SlackIngestStatus {
  connected: boolean
  reason?: string
  channel_id?: string
}

export function getSlackIngestStatus(): Promise<SlackIngestStatus> {
  return request<SlackIngestStatus>("/api/slack/status")
}

export function setSlackChannel(channelId: string): Promise<{ slack_channel_id?: string }> {
  return request<{ slack_channel_id?: string }>("/api/slack/channel", {
    method: "PUT",
    body: JSON.stringify({ channel_id: channelId }),
  })
}

export interface MailStatus {
  connected: boolean
  /** Why the mailbox isn't usable — set only when `connected` is false. */
  reason?: string
  /** The mailbox actually authorised, discovered from the OAuth grant. */
  email?: string | null
}

export function getMailStatus(): Promise<MailStatus> {
  return request<MailStatus>("/api/mail/status")
}

export function disconnectMail(): Promise<MailStatus> {
  return request<MailStatus>("/api/mail/disconnect", { method: "POST" })
}

// Opens the OAuth consent browser tab on the machine running this server and blocks until
// the person finishes (or abandons) it — see brain/viz_server.py's mail_connect().
export function connectMail(): Promise<MailStatus> {
  return request<MailStatus>("/api/mail/connect", { method: "POST" })
}

export interface CalendarStatus {
  connected: boolean
  /** Why the calendar isn't usable — set only when `connected` is false. */
  reason?: string
}

export function getCalendarStatus(): Promise<CalendarStatus> {
  return request<CalendarStatus>("/api/calendar/status")
}

export function disconnectCalendar(): Promise<CalendarStatus> {
  return request<CalendarStatus>("/api/calendar/disconnect", { method: "POST" })
}

// Same shape as connectMail(): opens the OAuth consent browser tab on the machine running this
// server and blocks until the person finishes (or abandons) it — see brain/viz_server.py's
// calendar_connect().
export function connectCalendar(): Promise<CalendarStatus> {
  return request<CalendarStatus>("/api/calendar/connect", { method: "POST" })
}

/** Reverses an auto-created calendar event — the "Undo" button on the post-sync popup. */
export function undoCalendarEvent(eventId: string, threadId: string): Promise<{ undone: boolean }> {
  return request<{ undone: boolean }>(`/api/calendar/events/${encodeURIComponent(eventId)}/undo`, {
    method: "POST",
    body: JSON.stringify({ thread_id: threadId }),
  })
}

export interface MailAskProfileDetail {
  key: string
  value: string
}

export interface MailAskResponse {
  answer: string
}

export function askMail(
  question: string,
  profileDetails: MailAskProfileDetail[],
): Promise<MailAskResponse> {
  return request<MailAskResponse>("/api/mail/ask", {
    method: "POST",
    body: JSON.stringify({ question, profile_details: profileDetails }),
  })
}

export interface ProfileDetailPayload {
  key: string
  value: string
}

export interface ProfileResult {
  details: ProfileDetailPayload[]
  /** Which details the mail pipeline treats as "you" when scanning attachments. */
  identifiers: string[]
}

export function getProfile(): Promise<ProfileResult> {
  return request<ProfileResult>("/api/profile")
}

export function saveProfile(details: ProfileDetailPayload[]): Promise<ProfileResult> {
  return request<ProfileResult>("/api/profile", {
    method: "PUT",
    body: JSON.stringify({ details }),
  })
}

export interface MailSettings {
  /** When true, mail ingest never calls the LLM — pure keyword classification, no thread
   * summarization/merging synthesis, no calendar-event extraction. See brain/mail_ingest.py. */
  offline_mode: boolean
  /** The Slack channel ID /api/slack/reload pulls history from, or "" if unset. */
  slack_channel_id: string
}

export function getSettings(): Promise<MailSettings> {
  return request<MailSettings>("/api/settings")
}

export function setOfflineMode(enabled: boolean): Promise<MailSettings> {
  return request<MailSettings>("/api/settings", {
    method: "PUT",
    body: JSON.stringify({ offline_mode: enabled }),
  })
}

export interface MailReviewItem {
  id: string
  name: string
  summary?: string | null
  category?: string | null
  topic?: string | null
  llm_category?: string | null
  keyword_category?: string | null
  scores?: Record<string, number>
}

export interface MailReviewResult {
  threads: MailReviewItem[]
  categories: string[]
}

/** Threads the classifier wasn't confident about, plus the categories to move them into. */
export function getMailReview(): Promise<MailReviewResult> {
  return request<MailReviewResult>("/api/mail/review")
}

// Move a thread to a different category (and optionally topic). Omitting `topic` keeps the
// thread's current topic name, so a category-only correction preserves its grouping.
export function reclassifyThread(
  threadId: string,
  category: string,
  topic?: string,
): Promise<MailReclassifyResult> {
  return request<MailReclassifyResult>("/api/mail/reclassify", {
    method: "POST",
    body: JSON.stringify({ thread_id: threadId, category, topic: topic ?? null }),
  })
}

export interface NeedsAttentionItem {
  id: string
  name: string
  summary?: string | null
  category?: string | null
  topic?: string | null
  channel: string
}

/** Threads flagged urgent by the deterministic keyword detector, across every channel. */
export function getNeedsAttention(): Promise<{ threads: NeedsAttentionItem[] }> {
  return request<{ threads: NeedsAttentionItem[] }>("/api/needs-attention")
}

export interface ActionItem {
  text: string
  thread_id: string
  thread_name: string
  category?: string | null
  topic?: string | null
  channel: string
}

/** Every extracted to-do, flattened across all threads and channels into one list. */
export function getActionItems(): Promise<{ items: ActionItem[] }> {
  return request<{ items: ActionItem[] }>("/api/action-items")
}

export interface CategoryVolumePoint {
  bucket: string
  category: string
  count: number
}

/** Thread count per category per time bucket — already-timestamped data, pure aggregation. */
export function getCategoryVolume(bucket: "day" | "week" = "day"): Promise<{ bucket: string; points: CategoryVolumePoint[] }> {
  return request(`/api/analytics/category-volume?bucket=${bucket}`)
}
