// The mind-map's time view, filters and colours — all derived from the same thread nodes the
// topic view shows, at render time. Nothing here is stored: the brain keeps dates as thread
// attributes (brain/mail_timeline.py), and urgency is recomputed against today on every render
// so "due soon" can never go stale.
import type { MailEvent, MailNode } from "@/lib/brainApi"

export type ThreadStatus = "overdue" | "soon" | "upcoming" | "past" | "none"
export type TimeMode = "upcoming" | "received"
export type TimeFilter = "all" | "overdue" | "week" | "upcoming" | "recent"

// Keep in step with brain/mail_timeline.py, which applies the same rules for chat answers.
const SOON_DAYS = 3
const OVERDUE_WINDOW_DAYS = 14
const DAY_MS = 86_400_000
export const NEW_WITHIN_MS = DAY_MS
export const STALE_AFTER_DAYS = 30

export const STATUS_COLORS: Record<ThreadStatus, string | null> = {
  overdue: "#ef4444",
  soon: "#f59e0b",
  upcoming: "#3b82f6",
  past: null,
  none: null,
}

export const STATUS_LABELS: Record<ThreadStatus, string> = {
  overdue: "Overdue",
  soon: "Due within 3 days",
  upcoming: "Upcoming",
  past: "Past",
  none: "No date",
}

/** Short label for one event's status chip. */
export function eventStatusLabel(status: ThreadStatus, kind: MailEvent["kind"]): string {
  if (status === "soon") return kind === "deadline" ? "Due soon" : "Soon"
  if (status === "past") return kind === "deadline" ? "Passed" : "Done"
  return STATUS_LABELS[status]
}

// Category hues avoid red, amber and blue, which belong to urgency. Ordered so the first few
// are as far apart as possible — most inboxes have only a handful of categories.
const CATEGORY_PALETTE = [
  "#8b5cf6", "#10b981", "#ec4899", "#06b6d4", "#a3e635", "#d946ef", "#6366f1", "#14b8a6",
]

export function startOfDay(d: Date): Date {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate())
}

/** The calendar day an event is on, as written in the mail — not shifted into local time. */
function eventDay(event: MailEvent): Date | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(event.start)
  return m ? new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3])) : null
}

function dayDiff(a: Date, b: Date): number {
  return Math.round((startOfDay(a).getTime() - startOfDay(b).getTime()) / DAY_MS)
}

export interface StatusInfo {
  status: ThreadStatus
  event: MailEvent | null
  days: number | null
}

export function threadStatus(node: MailNode, today: Date): StatusInfo {
  const dated = (node.events ?? [])
    .map((event) => ({ event, day: eventDay(event) }))
    .filter((e): e is { event: MailEvent; day: Date } => e.day !== null)
  const upcoming = dated.filter((e) => dayDiff(e.day, today) >= 0).sort((a, b) => +a.day - +b.day)
  if (upcoming.length) {
    const days = dayDiff(upcoming[0].day, today)
    return { status: days <= SOON_DAYS ? "soon" : "upcoming", event: upcoming[0].event, days }
  }
  if (dated.length) {
    const latest = dated.reduce((a, b) => (b.day > a.day ? b : a))
    const days = dayDiff(latest.day, today)
    const overdue = latest.event.kind === "deadline" && -days <= OVERDUE_WINDOW_DAYS
    return { status: overdue ? "overdue" : "past", event: latest.event, days }
  }
  return { status: "none", event: null, days: null }
}

export function receivedAt(node: MailNode): Date | null {
  if (!node.last_received) return null
  const d = new Date(node.last_received)
  return Number.isNaN(d.getTime()) ? null : d
}

export function isNew(node: MailNode, now: Date): boolean {
  const r = receivedAt(node)
  return !node.received_estimated && r !== null && now.getTime() - r.getTime() < NEW_WITHIN_MS
}

/** Old, with nothing pending — drawn faded so what matters stands out. */
export function isStale(node: MailNode, now: Date): boolean {
  const r = receivedAt(node)
  const { status } = threadStatus(node, now)
  return r !== null && (status === "none" || status === "past") && dayDiff(now, r) > STALE_AFTER_DAYS
}

const fmtDay = new Intl.DateTimeFormat(undefined, { weekday: "short", day: "numeric", month: "short" })
const fmtMonth = new Intl.DateTimeFormat(undefined, { month: "long", year: "numeric" })

export function formatEventDate(event: MailEvent): string {
  const day = eventDay(event)
  if (!day) return event.start
  const time = /T(\d{2}):(\d{2})/.exec(event.start)
  const hasTime = time && !(time[1] === "00" && time[2] === "00")
  return hasTime ? `${fmtDay.format(day)}, ${time[1]}:${time[2]}` : fmtDay.format(day)
}

export function relativeDays(days: number): string {
  if (days === 0) return "today"
  if (days === 1) return "tomorrow"
  if (days === -1) return "yesterday"
  return days > 0 ? `in ${days} days` : `${-days} days ago`
}

function relativeAgo(then: Date, now: Date): string {
  const mins = Math.round((now.getTime() - then.getTime()) / 60_000)
  if (mins < 60) return `${Math.max(mins, 1)}m ago`
  const hours = Math.round(mins / 60)
  if (hours < 24) return `${hours}h ago`
  return relativeDays(-dayDiff(now, then))
}

/** The second line under a thread's title: its most pressing date, or when it arrived. */
export function threadMeta(node: MailNode, now: Date): string {
  const { status, event, days } = threadStatus(node, now)
  if (event && days !== null && status !== "past") {
    if (status === "overdue") return `Overdue · was due ${formatEventDate(event)}`
    const lead = event.kind === "deadline" ? "Due" : ""
    return `${lead ? `${lead} ` : ""}${formatEventDate(event)} · ${relativeDays(days)}`
  }
  const r = receivedAt(node)
  if (!r) return ""
  return `Received ${node.received_estimated ? "~" : ""}${relativeAgo(r, now)}`
}

// --- category colours ------------------------------------------------------------------------

/**
 * A colour per category, assigned in alphabetical order so it's the same in both views and
 * across reloads, and so a small set of categories always gets the most distinct hues. (A
 * name hash would survive categories being added, but lands two categories on neighbouring
 * greens far too often to be readable.)
 */
export function categoryColors(root: MailNode): Map<string, string> {
  const names = [...new Set((root.children ?? []).filter((c) => c.type === "mail_category").map((c) => c.name))]
  names.sort((a, b) => a.localeCompare(b))
  return new Map(names.map((name, i) => [name, CATEGORY_PALETTE[i % CATEGORY_PALETTE.length]]))
}

// --- filtering -------------------------------------------------------------------------------

export function collectThreads(node: MailNode): MailNode[] {
  if (node.type === "mail_thread") return [node]
  return (node.children ?? []).flatMap(collectThreads)
}

export function matchesFilter(node: MailNode, filter: TimeFilter, query: string, now: Date): boolean {
  const q = query.trim().toLowerCase()
  if (q) {
    const haystack = [node.name, node.summary, node.topic, node.category, ...(node.events ?? []).map((e) => e.title)]
      .filter(Boolean)
      .join(" ")
      .toLowerCase()
    if (!haystack.includes(q)) return false
  }
  if (filter === "all") return true
  const { status, days } = threadStatus(node, now)
  if (filter === "overdue") return status === "overdue"
  if (filter === "week") return (status === "soon" || status === "upcoming") && days !== null && days <= 7
  if (filter === "upcoming") return status === "soon" || status === "upcoming"
  const r = receivedAt(node)
  return r !== null && dayDiff(now, r) <= 7
}

/** A copy of the tree keeping only matching threads, and dropping branches left empty. */
export function filterTree(node: MailNode, keep: (thread: MailNode) => boolean): MailNode | null {
  if (node.type === "mail_thread") return keep(node) ? node : null
  const children = (node.children ?? [])
    .map((c) => filterTree(c, keep))
    .filter((c): c is MailNode => c !== null)
  if (!children.length && node.type !== "root") return null
  return { ...node, children }
}

// --- the time view ---------------------------------------------------------------------------

function bucket(id: string, name: string, threads: MailNode[]): MailNode {
  return {
    id: `time:${id}`,
    name,
    type: "time_bucket",
    summary: `${threads.length} thread${threads.length === 1 ? "" : "s"}`,
    children: threads,
  }
}

/** Buckets that start collapsed: history nobody needs to see first. */
export const COLLAPSED_BUCKETS = new Set(["time:upcoming:past", "time:upcoming:none"])

function upcomingTree(threads: MailNode[], now: Date): MailNode[] {
  const groups: Record<string, { name: string; items: { node: MailNode; sort: number }[] }> = {
    overdue: { name: "Overdue", items: [] },
    today: { name: "Today", items: [] },
    week: { name: "This week", items: [] },
    next: { name: "Next week", items: [] },
    later: { name: "Later", items: [] },
    past: { name: "Past events", items: [] },
    none: { name: "No date", items: [] },
  }
  for (const node of threads) {
    const { status, days } = threadStatus(node, now)
    const d = days ?? 0
    const key =
      status === "overdue" ? "overdue"
      : status === "past" ? "past"
      : status === "none" ? "none"
      : d === 0 ? "today"
      : d <= 7 ? "week"
      : d <= 14 ? "next"
      : "later"
    // Overdue and past read most-recent first; everything ahead reads soonest first.
    const sort = key === "none" ? -(receivedAt(node)?.getTime() ?? 0) : key === "overdue" || key === "past" ? -d : d
    groups[key].items.push({ node, sort })
  }
  return Object.entries(groups)
    .filter(([, g]) => g.items.length)
    .map(([key, g]) =>
      bucket(`upcoming:${key}`, g.name, g.items.sort((a, b) => a.sort - b.sort).map((i) => i.node)),
    )
}

function receivedTree(threads: MailNode[]): MailNode[] {
  const dated = threads
    .map((node) => ({ node, at: receivedAt(node) }))
    .sort((a, b) => (b.at?.getTime() ?? 0) - (a.at?.getTime() ?? 0))
  const months = new Map<string, { label: string; days: Map<string, { label: string; nodes: MailNode[] }> }>()
  const undated: MailNode[] = []
  for (const { node, at } of dated) {
    if (!at) {
      undated.push(node)
      continue
    }
    const monthKey = `${at.getFullYear()}-${String(at.getMonth() + 1).padStart(2, "0")}`
    const dayKey = `${monthKey}-${String(at.getDate()).padStart(2, "0")}`
    if (!months.has(monthKey)) months.set(monthKey, { label: fmtMonth.format(at), days: new Map() })
    const month = months.get(monthKey)!
    if (!month.days.has(dayKey)) month.days.set(dayKey, { label: fmtDay.format(at), nodes: [] })
    month.days.get(dayKey)!.nodes.push(node)
  }
  const out: MailNode[] = [...months.entries()].map(([monthKey, month]) => {
    const days = [...month.days.entries()].map(([dayKey, day]) =>
      bucket(`received:${dayKey}`, day.label, day.nodes),
    )
    const count = days.reduce((n, d) => n + (d.children?.length ?? 0), 0)
    return { ...bucket(`received:${monthKey}`, month.label, []), children: days, summary: `${count} thread${count === 1 ? "" : "s"}` }
  })
  if (undated.length) out.push(bucket("received:unknown", "Unknown date", undated))
  return out
}

export function buildTimeTree(data: MailNode, mode: TimeMode, now: Date): MailNode {
  const threads = collectThreads(data)
  return {
    id: `time:root:${mode}`,
    name: mode === "upcoming" ? "Upcoming" : "Received",
    type: "root",
    children: mode === "upcoming" ? upcomingTree(threads, now) : receivedTree(threads),
  }
}
