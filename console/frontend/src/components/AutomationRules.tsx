// Natural-language automation rules ("notify me on Slack when a Placements email arrives").
// The text is parsed into a structured trigger by one LLM call at creation time only (see
// brain/automation.py) — evaluating a rule against every future message costs nothing.
import { Loader2, Trash2, Zap } from "lucide-react"
import { useEffect, useState } from "react"

import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { type AutomationRule, createRule, deleteRule, getRules } from "@/lib/brainApi"

export function AutomationRules() {
  const [rules, setRules] = useState<AutomationRule[]>([])
  const [loading, setLoading] = useState(true)
  const [text, setText] = useState("")
  const [creating, setCreating] = useState(false)
  const [error, setError] = useState<string | null>(null)

  function load() {
    getRules()
      .then((r) => setRules(r.rules))
      .catch(() => setError("Couldn't load automation rules."))
      .finally(() => setLoading(false))
  }

  useEffect(load, [])

  async function submit() {
    const trimmed = text.trim()
    if (!trimmed) return
    setCreating(true)
    setError(null)
    try {
      const rule = await createRule(trimmed)
      setRules((prev) => [...prev, rule])
      setText("")
    } catch (err) {
      setError(err instanceof Error ? err.message : "Couldn't parse that rule.")
    } finally {
      setCreating(false)
    }
  }

  async function remove(ruleId: string) {
    setRules((prev) => prev.filter((r) => r.id !== ruleId))
    try {
      await deleteRule(ruleId)
    } catch {
      load() // the optimistic removal didn't stick — resync with the server
    }
  }

  return (
    <Card>
      <CardHeader className="flex-row items-center gap-2 space-y-0">
        <Zap className="h-4 w-4 text-primary" />
        <CardTitle className="text-base">Automation rules</CardTitle>
      </CardHeader>
      <CardContent className="flex flex-col gap-4">
        <p className="text-sm text-muted-foreground">
          Describe a rule in plain English — e.g. "notify me on Slack when a Placements email
          arrives" — and it fires on every future message that matches.
        </p>
        <div className="flex gap-2">
          <Input
            value={text}
            onChange={(e) => setText(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && submit()}
            placeholder="Notify me on Slack when a Placements email arrives"
          />
          <Button size="sm" onClick={submit} disabled={creating || !text.trim()}>
            {creating ? <Loader2 className="h-4 w-4 animate-spin" /> : "Add"}
          </Button>
        </div>
        {error && <p className="text-sm text-destructive">{error}</p>}

        {loading ? (
          <p className="text-sm text-muted-foreground">Loading…</p>
        ) : rules.length === 0 ? (
          <p className="text-sm text-muted-foreground">No rules yet.</p>
        ) : (
          <ul className="flex flex-col divide-y divide-border">
            {rules.map((rule) => (
              <li key={rule.id} className="flex items-center justify-between gap-3 py-2.5">
                <div className="flex min-w-0 flex-col">
                  <span className="truncate text-sm font-medium">{rule.text}</span>
                  <span className="text-xs text-muted-foreground">
                    {rule.trigger_category ? `Category: ${rule.trigger_category}` : "Any category"}
                    {rule.trigger_urgent_only ? " · urgent only" : ""}
                  </span>
                </div>
                <div className="flex items-center gap-2 shrink-0">
                  <Badge variant={rule.enabled ? "default" : "outline"}>
                    {rule.enabled ? "Active" : "Disabled"}
                  </Badge>
                  <Button
                    size="icon"
                    variant="ghost"
                    onClick={() => remove(rule.id)}
                    aria-label={`Delete rule: ${rule.text}`}
                  >
                    <Trash2 className="h-4 w-4" />
                  </Button>
                </div>
              </li>
            ))}
          </ul>
        )}
      </CardContent>
    </Card>
  )
}
