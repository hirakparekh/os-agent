// Threads flagged urgent by brain/mail_ingest.py's deterministic keyword detector (no LLM),
// across every connected channel — a single worklist instead of hunting the mindmap node by
// node for an amber flag. Same list/card shape as MailReviewQueue.tsx for visual consistency.
import { AlertTriangle } from "lucide-react"
import { useEffect, useState } from "react"

import { Badge } from "@/components/ui/badge"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { type NeedsAttentionItem, getNeedsAttention } from "@/lib/brainApi"

export function NeedsAttentionPanel() {
  const [items, setItems] = useState<NeedsAttentionItem[]>([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    getNeedsAttention()
      .then((r) => setItems(r.threads))
      .catch(() => setItems([]))
      .finally(() => setLoading(false))
  }, [])

  if (loading || items.length === 0) return null

  return (
    <Card data-testid="needs-attention" className="border-destructive/30 bg-destructive/5">
      <CardHeader className="flex-row items-center justify-between space-y-0 pb-2">
        <CardTitle className="flex items-center gap-2 text-base">
          <AlertTriangle className="h-4 w-4 text-destructive" />
          Needs attention
          <span className="text-sm font-normal text-muted-foreground">({items.length})</span>
        </CardTitle>
      </CardHeader>
      <CardContent className="flex flex-col gap-3">
        <p className="text-sm text-muted-foreground">
          Flagged urgent by keyword — deadline/urgent language, no LLM involved.
        </p>
        <ul className="flex flex-col divide-y divide-border">
          {items.map((item) => (
            <li key={item.id} className="flex items-center justify-between gap-3 py-2.5">
              <div className="flex min-w-0 flex-col">
                <span className="truncate text-sm font-medium">{item.name}</span>
                <span className="text-xs text-muted-foreground">
                  {item.category ?? "Uncategorized"}
                  {item.topic ? ` › ${item.topic}` : ""}
                </span>
              </div>
              <Badge variant="outline" className="shrink-0 capitalize">
                {item.channel}
              </Badge>
            </li>
          ))}
        </ul>
      </CardContent>
    </Card>
  )
}
