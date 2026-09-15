import { Calendar, Check, Clock, ExternalLink, FileText, Hash, Mail, Plug, Plus, Shield, WifiOff, Zap } from "lucide-react"
import { useEffect, useState } from "react"
import { motion } from "framer-motion"

import { type Application, AVAILABLE_APPS, CORE_APPS, GMAIL_APP, GOOGLE_CALENDAR_APP, connectApp, disconnectApp, getHealth } from "@/api"
import { AutomationRules } from "@/components/AutomationRules"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import {
  disconnectCalendar,
  disconnectMail,
  runConsentFlow,
  startCalendarConnect,
  startMailConnect,
  getCalendarStatus,
  getMailStatus,
  getSettings,
  setOfflineMode,
} from "@/lib/brainApi"

function OfflineModeCard() {
  const [offline, setOffline] = useState<boolean | null>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    getSettings()
      .then((s) => setOffline(s.offline_mode))
      .catch(() => setOffline(false))
  }, [])

  async function toggle() {
    if (offline === null) return
    setBusy(true)
    try {
      const result = await setOfflineMode(!offline)
      setOffline(result.offline_mode)
    } catch {
      // Leave the switch as it was — the request failed, nothing changed server-side.
    } finally {
      setBusy(false)
    }
  }

  return (
    <Card className={offline ? "border-amber-500/30 bg-amber-500/5" : ""}>
      <CardContent className="flex flex-wrap items-center justify-between gap-4 py-5">
        <div className="flex items-start gap-3">
          <div className={`h-9 w-9 shrink-0 rounded-lg flex items-center justify-center ${offline ? "bg-amber-500/20" : "bg-secondary/80 border border-border/50"}`}>
            <WifiOff className={`h-4 w-4 ${offline ? "text-amber-500" : "text-muted-foreground"}`} />
          </div>
          <div>
            <p className="text-sm font-semibold">Offline mode</p>
            <p className="text-xs text-muted-foreground mt-0.5 max-w-md">
              Mail sync never calls the LLM — classification falls back to pure keyword
              matching, and thread summaries use the raw email text. Zero API cost.
            </p>
          </div>
        </div>
        <Button
          size="sm"
          variant={offline ? "default" : "outline"}
          disabled={offline === null || busy}
          onClick={toggle}
        >
          {offline === null ? "Loading…" : offline ? "On" : "Off"}
        </Button>
      </CardContent>
    </Card>
  )
}

// gmail and google_calendar are both Google OAuth flows served by the brain service, not this
// backend's generic /applications/{id}/connect. Each opens Google in a new tab and polls its
// own status endpoint until the server has exchanged the code (see brain/oauth_flow.py).
const GOOGLE_OAUTH_APPS: Record<
  string,
  {
    connect: () => Promise<{ connected: boolean; reason?: string }>
    disconnect: () => Promise<{ connected: boolean }>
  }
> = {
  gmail: {
    connect: () => runConsentFlow(startMailConnect, getMailStatus),
    disconnect: disconnectMail,
  },
  google_calendar: {
    connect: () => runConsentFlow(startCalendarConnect, getCalendarStatus),
    disconnect: disconnectCalendar,
  },
}

// Translucent tints rather than solid pastels so the badges read in both light and dark mode.
const APP_ICON: Record<string, { icon: typeof Plug; className: string }> = {
  gmail: { icon: Mail, className: "bg-red-500/10 text-red-500" },
  slack: { icon: Hash, className: "bg-fuchsia-500/10 text-fuchsia-500" },
  google_calendar: { icon: Calendar, className: "bg-blue-500/10 text-blue-500" },
  notion: { icon: FileText, className: "bg-neutral-500/10 text-neutral-500" },
}

function AppIcon({ id }: { id: string }) {
  const entry = APP_ICON[id] ?? { icon: Plug, className: "bg-primary/10 text-primary" }
  const Icon = entry.icon
  return (
    <span className={["flex h-8 w-8 shrink-0 items-center justify-center rounded-lg", entry.className].join(" ")}>
      <Icon className="h-4 w-4" />
    </span>
  )
}

function AppCard({ id, name, description, connected, kind, credentialLabel, onChanged }: Application & { onChanged?: () => void }) {
  const [open, setOpen] = useState(false)
  const [credential, setCredential] = useState("")
  const [busy, setBusy] = useState(false)
  const [note, setNote] = useState<string | null>(null)
  const [done, setDone] = useState(connected)

  useEffect(() => setDone(connected), [connected])

  async function submit() {
    setBusy(true)
    setNote(null)
    try {
      const res = await connectApp(id, kind === "token" ? credential : "")
      if (res.authUrl) {
        window.location.href = res.authUrl
        return
      }
      setDone(true)
      setOpen(false)
    } catch {
      setNote("Connecting this app isn't available yet.")
    } finally {
      setBusy(false)
    }
  }

  async function connectLocalOAuth() {
    const flow = GOOGLE_OAUTH_APPS[id]
    setBusy(true)
    setNote(null)
    try {
      const res = await flow.connect()
      setDone(res.connected)
      // Say *why* it didn't take. Consent can succeed at Google and still fail server-side,
      // and "try again" on a loop is the worst possible response to that.
      if (!res.connected) {
        setNote(res.reason ?? "Authorization wasn't completed — try again.")
      }
      onChanged?.()
    } catch (err) {
      const detail = err instanceof Error ? err.message : ""
      setNote(detail || "Couldn't reach the brain service — is it running?")
    } finally {
      setBusy(false)
    }
  }

  async function disconnect() {
    setBusy(true)
    setNote(null)
    try {
      const flow = GOOGLE_OAUTH_APPS[id]
      if (flow) {
        const res = await flow.disconnect()
        setDone(res.connected)
      } else {
        await disconnectApp(id)
        setDone(false)
      }
      onChanged?.()
    } catch {
      setNote("Disconnecting this app isn't available yet.")
    } finally {
      setBusy(false)
    }
  }

  return (
    <motion.div whileHover={{ y: -4 }} transition={{ type: "spring", stiffness: 300 }} className="h-full">
      <Card className={`h-full flex flex-col relative overflow-hidden transition-all duration-300 ${done ? 'border-primary/30 shadow-[0_4px_20px_rgba(79,70,229,0.05)]' : 'border-border/40 hover:border-border/80'}`}>

        {/* Subtle glow effect for connected apps */}
        {done && (
          <div className="absolute top-0 right-0 w-32 h-32 bg-primary/10 rounded-full blur-3xl -translate-y-1/2 translate-x-1/2 pointer-events-none" />
        )}

        {/* Description sits below the title/badge row, full width — beside the badge, long
            descriptions get squeezed into a one-word-per-line column. */}
        <CardHeader className="flex flex-col gap-2 pb-4">
          <div className="flex items-center justify-between gap-3 z-10">
            <div className="flex min-w-0 items-center gap-2">
              <AppIcon id={id} />
              <CardTitle className="truncate text-base font-semibold">{name}</CardTitle>
            </div>
            {done ? (
              <Badge variant="default" className="shrink-0 shadow-[0_0_10px_rgba(79,70,229,0.2)]">
                <Check className="mr-1.5 h-3 w-3" />
                Connected
              </Badge>
            ) : (
              <Badge variant="outline" className="shrink-0 border-border bg-transparent text-muted-foreground">
                <Clock className="mr-1.5 h-3 w-3" />
                Available
              </Badge>
            )}
          </div>
          <CardDescription className="z-10 text-xs leading-relaxed">{description}</CardDescription>
        </CardHeader>

        <CardContent className="flex flex-col gap-4 mt-auto pt-0 z-10">
          <div className="h-[1px] w-full bg-border/40 mb-2" />
          
          {id in GOOGLE_OAUTH_APPS && !done && (
            <div className="flex items-start gap-2 text-xs text-muted-foreground bg-secondary/30 p-2.5 rounded-md border border-border/40">
              <Shield className="h-3.5 w-3.5 shrink-0 mt-0.5" />
              <p>Opens Google sign-in in a new tab. Come back here once it says connected.</p>
            </div>
          )}

          {id in GOOGLE_OAUTH_APPS ? (
            <div className="flex gap-2 w-full">
              {!done && (
                <Button size="sm" onClick={connectLocalOAuth} disabled={busy} className="w-full relative overflow-hidden group">
                  <div className="absolute inset-0 bg-white/20 translate-y-full group-hover:translate-y-0 transition-transform duration-300 ease-in-out" />
                  {busy ? "Waiting for Google…" : "Connect Account"}
                </Button>
              )}
              {done && (
                <Button size="sm" variant="secondary" onClick={disconnect} disabled={busy} className="w-full text-destructive hover:bg-destructive/10 hover:text-destructive hover:border-destructive/30">
                  {busy ? "Disconnecting..." : "Disconnect"}
                </Button>
              )}
            </div>
          ) : !open ? (
            <div className="flex gap-2 w-full">
              <Button
                size="sm"
                variant={done ? "outline" : "default"}
                onClick={() => setOpen(true)}
                className="w-full"
              >
                {done ? "Manage Configuration" : "Configure Integration"}
              </Button>
              {done && (
                <Button size="sm" variant="ghost" onClick={disconnect} disabled={busy} className="px-3 text-destructive hover:bg-destructive/10">
                  Disconnect
                </Button>
              )}
            </div>
          ) : (
            <motion.div 
              initial={{ opacity: 0, height: 0 }} 
              animate={{ opacity: 1, height: 'auto' }}
              className="flex flex-col gap-3 rounded-lg border border-primary/20 bg-primary/5 p-4"
            >
              {kind === "token" ? (
                <div className="space-y-3">
                  <div className="space-y-1.5">
                    <Label htmlFor={`cred-${id}`} className="text-xs font-semibold text-primary/80 uppercase tracking-wider">{credentialLabel ?? "API Token"}</Label>
                    <Input
                      id={`cred-${id}`}
                      type="password"
                      value={credential}
                      onChange={(e) => setCredential(e.target.value)}
                      placeholder="Enter secret token..."
                      className="bg-card text-sm h-9"
                    />
                  </div>
                </div>
              ) : (
                <div className="flex items-start gap-2 text-sm text-muted-foreground">
                  <ExternalLink className="h-4 w-4 shrink-0 text-primary mt-0.5" />
                  <p>
                    You will be redirected to authenticate with {name}.
                  </p>
                </div>
              )}
              
              <div className="flex gap-2 mt-2">
                <Button size="sm" onClick={submit} disabled={busy} className="flex-1">
                  {busy ? <Zap className="h-4 w-4 animate-pulse mr-2" /> : null}
                  {busy ? "Connecting..." : "Confirm & Connect"}
                </Button>
                <Button
                  size="sm"
                  variant="ghost"
                  onClick={() => {
                    setOpen(false)
                    setNote(null)
                  }}
                >
                  Cancel
                </Button>
              </div>
            </motion.div>
          )}
          {note && (
            <motion.p initial={{ opacity: 0 }} animate={{ opacity: 1 }} className="text-xs text-destructive bg-destructive/10 p-2 rounded-md border border-destructive/20 text-center">
              {note}
            </motion.p>
          )}
        </CardContent>
      </Card>
    </motion.div>
  )
}

export function Applications({ onMailStatusChange }: { onMailStatusChange?: () => void }) {
  const [statuses, setStatuses] = useState<Record<string, boolean> | null>(null)
  const [gmailConnected, setGmailConnected] = useState(false)
  const [calendarConnected, setCalendarConnected] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    getHealth()
      .then((h) =>
        setStatuses(
          Object.fromEntries(h.integrations.map((i) => [i.name, i.status === "configured"])),
        ),
      )
      .catch(() => setError("Could not load applications."))

    getMailStatus()
      .then((s) => setGmailConnected(s.connected))
      .catch(() => setGmailConnected(false))

    getCalendarStatus()
      .then((s) => setCalendarConnected(s.connected))
      .catch(() => setCalendarConnected(false))
  }, [])

  if (error) return (
    <div className="flex flex-col items-center justify-center py-20 text-center">
      <div className="h-12 w-12 rounded-full bg-destructive/10 flex items-center justify-center mb-4">
        <Zap className="h-6 w-6 text-destructive" />
      </div>
      <p className="text-lg font-semibold text-destructive">Connection Error</p>
      <p className="text-sm text-muted-foreground mt-1">{error}</p>
    </div>
  )
  
  if (!statuses) return (
    <div className="flex flex-col items-center justify-center py-20">
      <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary mb-4"></div>
      <p className="text-sm text-muted-foreground">Loading integration status...</p>
    </div>
  )

  function handleChanged() {
    getMailStatus()
      .then((s) => setGmailConnected(s.connected))
      .catch(() => setGmailConnected(false))
    getCalendarStatus()
      .then((s) => setCalendarConnected(s.connected))
      .catch(() => setCalendarConnected(false))
    onMailStatusChange?.()
  }

  const all: Application[] = [
    { ...GMAIL_APP, connected: gmailConnected },
    { ...GOOGLE_CALENDAR_APP, connected: calendarConnected },
    ...Object.entries(CORE_APPS).map(([id, meta]) => ({
      id,
      ...meta,
      connected: statuses[id] ?? false,
    })),
    ...AVAILABLE_APPS,
  ]
  const connected = all.filter((a) => a.connected)
  const notConnected = all.filter((a) => !a.connected)

  return (
    <div className="flex flex-col gap-10">
      <div>
        <h1 className="text-3xl font-bold tracking-tight">Integrations</h1>
        <p className="text-muted-foreground mt-1 text-sm">Connect your tools to expand your agent's capabilities.</p>
      </div>

      <OfflineModeCard />

      {connected.length > 0 && (
        <section className="flex flex-col gap-4">
          <div className="flex items-center gap-2 pb-2 border-b border-border/50">
            <Plug className="h-4 w-4 text-emerald-500" />
            <h2 className="text-sm font-semibold text-foreground uppercase tracking-wider">Active Connections</h2>
            <Badge variant="secondary" className="ml-2 bg-secondary/50">{connected.length}</Badge>
          </div>
          <div className="grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
            {connected.map((app) => (
              <AppCard key={app.id} {...app} onChanged={handleChanged} />
            ))}
          </div>
        </section>
      )}

      <section className="flex flex-col gap-4">
        <div className="flex items-center gap-2 pb-2 border-b border-border/50 mt-4">
          <Plus className="h-4 w-4 text-muted-foreground" />
          <h2 className="text-sm font-semibold text-foreground uppercase tracking-wider">Available Integrations</h2>
        </div>
        <div className="grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
          {notConnected.map((app) => (
            <AppCard key={app.id} {...app} onChanged={handleChanged} />
          ))}
        </div>
      </section>

      <AutomationRules />
    </div>
  )
}
