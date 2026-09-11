// Category volume over time — thread count per category per day/week, using data the mail
// pipeline already timestamps (created_at). Pure aggregation, no new collection.
//
// Categorical palette: the dataviz skill's validated reference order (blue/orange/aqua/
// yellow), capped at 4 series — a 5th+ category folds into "Other" (neutral gray) rather than
// generating a new hue, per the skill's non-negotiables. Two of these four (aqua, yellow) sit
// below 3:1 contrast on a light surface, which is why both a legend AND a plain data table are
// always shown (the skill's "relief rule": color-limited series need a non-color fallback).
import { BarChart3 } from "lucide-react"
import { useEffect, useMemo, useState } from "react"
import {
  Bar,
  BarChart,
  CartesianGrid,
  Legend,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts"

import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { type CategoryVolumePoint, getCategoryVolume } from "@/lib/brainApi"

const MAX_SERIES = 4
const OTHER = "Other"

const SERIES_VARS = ["--analytics-series-1", "--analytics-series-2", "--analytics-series-3", "--analytics-series-4"]
const OTHER_VAR = "--analytics-series-other"

function pivot(points: CategoryVolumePoint[]): { rows: Record<string, string | number>[]; categories: string[] } {
  const totals = new Map<string, number>()
  for (const p of points) totals.set(p.category, (totals.get(p.category) ?? 0) + p.count)
  const ranked = [...totals.entries()].sort((a, b) => b[1] - a[1]).map(([name]) => name)
  const top = ranked.slice(0, MAX_SERIES)
  const categories = ranked.length > MAX_SERIES ? [...top, OTHER] : top

  const byBucket = new Map<string, Record<string, string | number>>()
  for (const p of points) {
    const row = byBucket.get(p.bucket) ?? { bucket: p.bucket }
    const key = top.includes(p.category) ? p.category : OTHER
    row[key] = (Number(row[key]) || 0) + p.count
    byBucket.set(p.bucket, row)
  }
  const rows = [...byBucket.values()].sort((a, b) => String(a.bucket).localeCompare(String(b.bucket)))
  return { rows, categories }
}

export function Analytics() {
  const [bucket, setBucket] = useState<"day" | "week">("day")
  const [points, setPoints] = useState<CategoryVolumePoint[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    setLoading(true)
    getCategoryVolume(bucket)
      .then((r) => {
        setPoints(r.points)
        setError(null)
      })
      .catch(() => setError("Could not load analytics."))
      .finally(() => setLoading(false))
  }, [bucket])

  const { rows, categories } = useMemo(() => pivot(points), [points])

  return (
    <div className="flex flex-col gap-6 analytics-root">
      <style>{`
        .analytics-root {
          --analytics-series-1: #2a78d6;
          --analytics-series-2: #eb6834;
          --analytics-series-3: #1baf7a;
          --analytics-series-4: #eda100;
          --analytics-series-other: #8b8a85;
        }
        .dark .analytics-root {
          --analytics-series-1: #3987e5;
          --analytics-series-2: #d95926;
          --analytics-series-3: #199e70;
          --analytics-series-4: #c98500;
          --analytics-series-other: #9c9b95;
        }
      `}</style>

      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-3xl font-bold tracking-tight">Analytics</h1>
          <p className="text-muted-foreground mt-1 text-sm">Mail volume by category over time.</p>
        </div>
        <div className="flex items-center gap-2">
          <Button size="sm" variant={bucket === "day" ? "default" : "outline"} onClick={() => setBucket("day")}>
            Day
          </Button>
          <Button size="sm" variant={bucket === "week" ? "default" : "outline"} onClick={() => setBucket("week")}>
            Week
          </Button>
        </div>
      </div>

      <Card>
        <CardHeader className="flex-row items-center gap-2 space-y-0">
          <BarChart3 className="h-4 w-4 text-primary" />
          <CardTitle className="text-base">Volume by category</CardTitle>
        </CardHeader>
        <CardContent>
          {error && <p className="text-sm text-destructive">{error}</p>}
          {!error && loading && <p className="text-sm text-muted-foreground">Loading…</p>}
          {!error && !loading && rows.length === 0 && (
            <p className="text-sm text-muted-foreground">No mail ingested yet.</p>
          )}
          {!error && !loading && rows.length > 0 && (
            <div className="h-80 w-full">
              <ResponsiveContainer width="100%" height="100%">
                <BarChart data={rows}>
                  <CartesianGrid strokeDasharray="3 3" className="stroke-border" vertical={false} />
                  <XAxis dataKey="bucket" tick={{ fontSize: 12 }} className="fill-muted-foreground" />
                  <YAxis allowDecimals={false} tick={{ fontSize: 12 }} className="fill-muted-foreground" />
                  <Tooltip
                    contentStyle={{
                      background: "var(--card)",
                      border: "1px solid var(--border)",
                      borderRadius: 8,
                      fontSize: 12,
                    }}
                  />
                  <Legend wrapperStyle={{ fontSize: 12 }} />
                  {categories.map((category, i) => (
                    <Bar
                      key={category}
                      dataKey={category}
                      stackId="volume"
                      fill={`var(${category === OTHER ? OTHER_VAR : SERIES_VARS[i]})`}
                      radius={i === categories.length - 1 ? [4, 4, 0, 0] : undefined}
                    />
                  ))}
                </BarChart>
              </ResponsiveContainer>
            </div>
          )}
        </CardContent>
      </Card>

      {/* The relief rule: two of the four series colors read poorly on a light surface, so the
          numbers are always available as plain text too, not just as bar height + color. */}
      {!error && !loading && rows.length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle className="text-sm text-muted-foreground font-medium">Data table</CardTitle>
          </CardHeader>
          <CardContent className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-border text-left text-muted-foreground">
                  <th className="py-2 pr-4 font-medium">{bucket === "day" ? "Date" : "Week"}</th>
                  {categories.map((c) => (
                    <th key={c} className="py-2 pr-4 font-medium">{c}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {rows.map((row) => (
                  <tr key={String(row.bucket)} className="border-b border-border/50">
                    <td className="py-2 pr-4">{row.bucket}</td>
                    {categories.map((c) => (
                      <td key={c} className="py-2 pr-4">{row[c] ?? 0}</td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </CardContent>
        </Card>
      )}
    </div>
  )
}
