import { LogOut, PanelLeftClose, PanelLeftOpen } from "lucide-react"
import { useEffect, useState } from "react"
import { LayoutDashboard, MessageSquare, User, Plug, CheckCircle2, XCircle, BarChart3 } from "lucide-react"
import { motion, AnimatePresence } from "framer-motion"

import { getHealth, getMe } from "@/api"
import { clearToken, getToken, onAuthChange, setRole, setToken } from "@/auth"
import { getCalendarStatus, getMailStatus, getMailTree } from "@/lib/brainApi"
import { Analytics } from "@/pages/Analytics"
import { Applications } from "@/pages/Applications"
import { Chat } from "@/pages/Chat"
import { Home } from "@/pages/Home"
import { Login } from "@/pages/Login"
import { Profile } from "@/pages/Profile"
import { ThemeToggle } from "@/components/ThemeToggle"

export type View = "chat" | "mail" | "analytics" | "profile" | "applications"

const NAV: { view: View; label: string; icon: typeof LayoutDashboard }[] = [
  { view: "chat", label: "Chat", icon: MessageSquare },
  { view: "mail", label: "Mail", icon: LayoutDashboard },
  { view: "analytics", label: "Analytics", icon: BarChart3 },
  { view: "applications", label: "Integrations", icon: Plug },
  { view: "profile", label: "Profile", icon: User },
]

interface Rail {
  appsConnected: number
  appsTotal: number
  mailThreads: number | null
  mailConnected: boolean | null
}

export default function App() {
  const [token, setTokenState] = useState<string | null>(getToken())
  const [checkingSession, setCheckingSession] = useState(!!getToken())
  const [view, setView] = useState<View>("chat")
  // Persisted per-browser, not per-account — a layout preference, not app state worth syncing.
  const [sidebarCollapsed, setSidebarCollapsed] = useState(
    () => localStorage.getItem("sidebarCollapsed") === "1",
  )
  useEffect(() => {
    localStorage.setItem("sidebarCollapsed", sidebarCollapsed ? "1" : "0")
  }, [sidebarCollapsed])
  // A question handed from the Mail tab to the Chat tab ("Ask about this thread"). Lives here
  // because the two are sibling views with no router to carry state between them.
  const [chatSeed, setChatSeed] = useState<string | null>(null)
  const [refreshKey, setRefreshKey] = useState(0)
  const [rail, setRail] = useState<Rail>({
    appsConnected: 0,
    appsTotal: 0,
    mailThreads: null,
    mailConnected: null,
  })

  // Re-sync whenever a 401 from either API client (api.ts or brainApi.ts) clears the token
  // out from under this component.
  useEffect(() => onAuthChange(() => setTokenState(getToken())), [])

  // On mount (and whenever a token appears), validate it against the backend once — catches
  // an expired/invalid token left in localStorage from a previous session.
  useEffect(() => {
    if (!token) {
      setCheckingSession(false)
      return
    }
    let cancelled = false
    setCheckingSession(true)
    getMe()
      .then((me) => {
        if (cancelled) return
        setRole(me.role)
      })
      .catch(() => {
        if (cancelled) return
        clearToken()
      })
      .finally(() => {
        if (!cancelled) setCheckingSession(false)
      })
    return () => {
      cancelled = true
    }
  }, [token])

  useEffect(() => {
    if (!token) return
    let cancelled = false

    // The rail's "connections" count is exactly the three cards the Integrations page actually
    // shows (Gmail, Google Calendar, Slack) — not console/backend's /health, which still
    // reports clickup/fathom even though neither has a UI card anymore (see console/backend/
    // health.py). Counting those as part of the denominator is what produced the wrong "2/4".
    Promise.all([
      getHealth(),
      getMailStatus().catch(() => ({ connected: false })),
      getCalendarStatus().catch(() => ({ connected: false })),
    ]).then(([health, mail, calendar]) => {
      if (cancelled) return
      const slackConnected = health.integrations.some(
        (i) => i.name === "slack" && i.status === "configured",
      )
      const connected =
        (mail.connected ? 1 : 0) + (calendar.connected ? 1 : 0) + (slackConnected ? 1 : 0)
      setRail((r) => ({
        ...r,
        appsConnected: connected,
        appsTotal: 3,
        mailConnected: mail.connected,
      }))
    })

    getMailTree()
      .then((tree) => {
        if (cancelled) return
        let threads = 0
        const walk = (n: typeof tree) => {
          if (n.type === "mail_thread") threads++
          ;(n.children || []).forEach(walk)
        }
        walk(tree)
        setRail((r) => ({ ...r, mailThreads: threads }))
      })
      .catch(() => {
        if (!cancelled) setRail((r) => ({ ...r, mailThreads: null }))
      })

    return () => {
      cancelled = true
    }
  }, [token, refreshKey])

  const refresh = () => setRefreshKey((k) => k + 1)

  function handleLogin(nextToken: string) {
    setToken(nextToken)
    setTokenState(nextToken)
  }

  function handleLogout() {
    clearToken()
    setTokenState(null)
  }

  if (!token) {
    return <Login onLogin={handleLogin} />
  }

  if (checkingSession) {
    return (
      <div className="flex min-h-screen items-center justify-center">
        <p className="text-sm text-muted-foreground">Signing you in…</p>
      </div>
    )
  }

  return (
    <div className="flex min-h-screen bg-background text-foreground selection:bg-primary/30">
      {/* Sidebar Navigation */}
      <aside
        className={`${sidebarCollapsed ? "w-20" : "w-64"} border-r border-border bg-card flex-col hidden md:flex z-10 shadow-xl shadow-black/10 transition-[width] duration-200`}
      >
        <div className="h-16 flex items-center justify-between px-4 border-b border-border/50">
          <div className="flex items-center gap-3 min-w-0">
            <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-primary text-sm font-bold text-primary-foreground shadow-[0_0_15px_rgba(79,70,229,0.5)]">
              A
            </div>
            {!sidebarCollapsed && (
              <span className="text-sm font-semibold tracking-wide truncate">Agent OS</span>
            )}
          </div>
          <button
            type="button"
            onClick={() => setSidebarCollapsed((c) => !c)}
            aria-label={sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar"}
            className="flex h-7 w-7 shrink-0 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-secondary/50 hover:text-foreground"
          >
            {sidebarCollapsed ? (
              <PanelLeftOpen className="h-4 w-4" />
            ) : (
              <PanelLeftClose className="h-4 w-4" />
            )}
          </button>
        </div>

        <nav className="flex-1 px-4 py-6 space-y-1">
          {NAV.map((n) => {
            const Icon = n.icon
            const active = view === n.view
            return (
              <button
                key={n.view}
                type="button"
                onClick={() => setView(n.view)}
                title={sidebarCollapsed ? n.label : undefined}
                className={`w-full flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm font-medium transition-all duration-200 ${
                  sidebarCollapsed ? "justify-center" : ""
                } ${
                  active
                    ? "bg-primary/10 text-primary"
                    : "text-muted-foreground hover:bg-secondary/50 hover:text-foreground"
                }`}
              >
                <Icon className={`h-4 w-4 shrink-0 ${active ? "text-primary" : "opacity-70"}`} />
                {!sidebarCollapsed && n.label}
              </button>
            )
          })}
        </nav>

        <div className="p-4 border-t border-border/50">
          {!sidebarCollapsed && (
            <div className="flex items-center justify-between text-[11px] uppercase tracking-wider font-semibold text-muted-foreground mb-3 px-2">
              <span>System Status</span>
              <ThemeToggle />
            </div>
          )}
          <div
            title={sidebarCollapsed ? (rail.mailConnected ? "Gmail Connected" : "Gmail Disconnected") : undefined}
            className={`flex items-center gap-3 rounded-lg bg-secondary/30 py-2.5 border border-border/30 ${
              sidebarCollapsed ? "justify-center px-0" : "px-3"
            }`}
          >
            {rail.mailConnected ? (
              <CheckCircle2 className="h-4 w-4 shrink-0 text-emerald-500" />
            ) : (
              <XCircle className="h-4 w-4 shrink-0 text-muted-foreground" />
            )}
            {!sidebarCollapsed && (
              <span className="text-xs font-medium text-secondary-foreground">
                {rail.mailConnected ? "Gmail Connected" : "Gmail Disconnected"}
              </span>
            )}
          </div>
          {sidebarCollapsed && (
            <div className="mt-3 flex justify-center">
              <ThemeToggle />
            </div>
          )}
          <button
            type="button"
            onClick={handleLogout}
            title={sidebarCollapsed ? "Log out" : undefined}
            className={`mt-3 flex w-full items-center gap-2 rounded-lg px-3 py-2 text-sm font-medium text-muted-foreground transition-colors hover:bg-secondary/50 hover:text-foreground ${
              sidebarCollapsed ? "justify-center" : ""
            }`}
          >
            <LogOut className="h-4 w-4 shrink-0" />
            {!sidebarCollapsed && "Log out"}
          </button>
        </div>
      </aside>

      {/* Main Content Area */}
      <main className="flex-1 flex flex-col h-screen overflow-hidden bg-background">
        {/* Mobile Header */}
        <header className="h-16 md:hidden flex items-center justify-between px-6 border-b border-border bg-card">
           <div className="flex items-center gap-3">
            <span className="flex h-8 w-8 items-center justify-center rounded-lg bg-primary text-sm font-bold text-primary-foreground shadow-lg shadow-primary/20">
              A
            </span>
            <span className="text-sm font-semibold">Agent OS</span>
          </div>

          <div className="flex items-center gap-2">
            <select
              value={view}
              onChange={(e) => setView(e.target.value as View)}
              className="text-sm bg-transparent border-none outline-none font-medium"
            >
              {NAV.map((n) => (
                <option key={n.view} value={n.view}>
                  {n.label}
                </option>
              ))}
            </select>
            <ThemeToggle />
            <button
              type="button"
              onClick={handleLogout}
              aria-label="Log out"
              className="flex h-9 w-9 items-center justify-center rounded-full border border-border bg-card text-muted-foreground transition-colors hover:text-foreground"
            >
              <LogOut className="h-4 w-4" />
            </button>
          </div>
        </header>

        {view === "chat" ? (
          <div className="min-h-0 flex-1">
            <Chat seed={chatSeed} onSeedConsumed={() => setChatSeed(null)} />
          </div>
        ) : (
          <div className="flex-1 overflow-auto p-6 md:p-10 relative">
            {/* Subtle background glow effect */}
            <div className="pointer-events-none absolute top-0 left-1/2 -translate-x-1/2 w-[800px] h-[400px] bg-primary/5 rounded-full blur-3xl opacity-50" />

            <div className="max-w-4xl mx-auto w-full relative z-10">
              <AnimatePresence mode="wait">
                <motion.div
                  key={view}
                  initial={{ opacity: 0, y: 15, filter: "blur(4px)" }}
                  animate={{ opacity: 1, y: 0, filter: "blur(0px)" }}
                  exit={{ opacity: 0, y: -15, filter: "blur(4px)" }}
                  transition={{ duration: 0.25, ease: "easeOut" }}
                >
                  {view === "mail" && (
                    <Home
                      rail={rail}
                      onNavigate={setView}
                      onAskAbout={(question) => {
                        setChatSeed(question)
                        setView("chat")
                      }}
                    />
                  )}
                  {view === "analytics" && <Analytics />}
                  {view === "applications" && <Applications onMailStatusChange={refresh} />}
                  {view === "profile" && <Profile />}
                </motion.div>
              </AnimatePresence>
            </div>
          </div>
        )}
      </main>
    </div>
  )
}
