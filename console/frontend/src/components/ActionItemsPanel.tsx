// Every to-do extracted by brain/mail_ingest.py's deterministic regex ("submit by Friday"
// style phrases), flattened across all threads and channels into one list — no LLM involved.
import { ListChecks } from "lucide-react"
import { useEffect, useState } from "react"

import { Badge } from "@/components/ui/badge"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { type ActionItem, getActionItems } from "@/lib/brainApi"

export function ActionItemsPanel() {
  const [items, setItems] = useState<ActionItem[]>([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    getActionItems()
      .then((r) => setItems(r.items))
      .catch(() => setItems([]))
      .finally(() => setLoading(false))
  }, [])

  if (loading || items.length === 0) return null

  return (
    <Card data-testid="action-items">
      <CardHeader className="flex-row items-center justify-between space-y-0 pb-2">
        <CardTitle className="flex items-center gap-2 text-base">
          <ListChecks className="h-4 w-4 text-primary" />
          Action items
          <span className="text-sm font-normal text-muted-foreground">({items.length})</span>
        </CardTitle>
      </CardHeader>
      <CardContent className="flex flex-col gap-3">
        <ul className="flex flex-col divide-y divide-border">
          {items.map((item, i) => (
            <li key={`${item.thread_id}-${i}`} className="flex items-center justify-between gap-3 py-2.5">
              <div className="flex min-w-0 flex-col">
                <span className="truncate text-sm font-medium capitalize">{item.text}</span>
                <span className="truncate text-xs text-muted-foreground">
                  {item.thread_name}
                  {item.category ? ` — ${item.category}` : ""}
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
