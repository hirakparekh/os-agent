// Direct port of brain/mail_tree.html's D3 collapsible-tree rendering into React, plus a time
// view: the same thread nodes regrouped by deadline or by arrival date (lib/mailTimeline.ts).
// Both views render from one fetched tree, so switching is instant and they can't disagree.
import * as d3 from "d3"
import { useEffect, useMemo, useRef, useState } from "react"

import { type MailNode, downloadMailTreeExport, reclassifyThread } from "@/lib/brainApi"
import {
  COLLAPSED_BUCKETS,
  STATUS_COLORS,
  STATUS_LABELS,
  type ThreadStatus,
  type TimeFilter,
  type TimeMode,
  buildTimeTree,
  categoryColors,
  collectThreads,
  eventStatusLabel,
  filterTree,
  formatEventDate,
  isNew,
  isStale,
  matchesFilter,
  relativeDays,
  threadMeta,
  threadStatus,
} from "@/lib/mailTimeline"

import "./MailMindmap.css"

type HierarchyNode = d3.HierarchyNode<MailNode> & {
  x0?: number
  y0?: number
  w?: number
  _children?: HierarchyNode[] | null
}

type View = "topic" | "time"

const DURATION = 260
const NODE_HEIGHT = 44
const NODE_GAP_Y = 14
const LEVEL_WIDTH = 280
const DOT_PAD = 12

const FILTERS: { id: TimeFilter; label: string }[] = [
  { id: "all", label: "All" },
  { id: "overdue", label: "Overdue" },
  { id: "week", label: "Due in 7 days" },
  { id: "upcoming", label: "Upcoming" },
  { id: "recent", label: "Received this week" },
]

const LEGEND_STATUSES: ThreadStatus[] = ["overdue", "soon", "upcoming"]

function truncate(text: string, max: number): string {
  return text.length > max ? text.slice(0, max - 2) + "…" : text
}

function collapse(d: HierarchyNode) {
  if (d.children) {
    d._children = d.children as HierarchyNode[]
    d._children.forEach(collapse)
    d.children = undefined
  }
}

function expandAll(d: HierarchyNode) {
  if (d._children) {
    d.children = d._children
    d._children = null
  }
  ;((d.children as HierarchyNode[] | undefined) ?? []).forEach(expandAll)
}

function toggleNode(d: HierarchyNode) {
  if (d.children) {
    d._children = d.children as HierarchyNode[]
    d.children = undefined
  } else if (d._children) {
    d.children = d._children
    d._children = null
  }
}

interface NodeCounts {
  mail_category: number
  mail_topic: number
  mail_thread: number
}

function countNodes(n: MailNode): NodeCounts {
  const counts: NodeCounts = { mail_category: 0, mail_topic: 0, mail_thread: 0 }
  const walk = (node: MailNode) => {
    if (node.type in counts) counts[node.type as keyof NodeCounts]++
    ;(node.children || []).forEach(walk)
  }
  walk(n)
  return counts
}

/** Which category a node belongs to, in either view. */
function categoryOf(d: HierarchyNode): string | null {
  if (d.data.type === "mail_category") return d.data.name
  if (d.data.type === "mail_thread") return d.data.category ?? null
  if (d.data.type === "mail_topic") return d.parent?.data.name ?? null
  return null
}

function hexToRgba(hex: string, alpha: number): string {
  const c = d3.color(hex)?.rgb()
  return c ? `rgba(${c.r},${c.g},${c.b},${alpha})` : hex
}

export function MailMindmap({
  data,
  onReclassified,
  onAskAbout,
}: {
  data: MailNode
  onReclassified?: () => void | Promise<void>
  /** Open a chat seeded with a question about the selected thread. */
  onAskAbout?: (question: string) => void
}) {
  const chartRef = useRef<HTMLDivElement>(null)
  const [detail, setDetail] = useState<HierarchyNode | null>(null)
  const [moveTo, setMoveTo] = useState("")
  const [moving, setMoving] = useState(false)
  const [moveError, setMoveError] = useState<string | null>(null)
  const [downloading, setDownloading] = useState(false)

  async function handleDownload() {
    setDownloading(true)
    try {
      await downloadMailTreeExport()
    } catch {
      // Best-effort — a failed download isn't worth its own error UI in this small toolbar.
    } finally {
      setDownloading(false)
    }
  }
  const [view, setView] = useState<View>("topic")
  const [timeMode, setTimeMode] = useState<TimeMode>("upcoming")
  const [filter, setFilter] = useState<TimeFilter>("all")
  const [query, setQuery] = useState("")

  // "Now" is pinned per fetched tree: urgency is recomputed every time the tree reloads, and a
  // stable value keeps the memoised views below from rebuilding on every keystroke's render.
  const now = useMemo(() => new Date(), [data])
  const counts = useMemo(() => countNodes(data), [data])
  const colors = useMemo(() => categoryColors(data), [data])
  const categoryNames = (data.children || []).map((c) => c.name)
  const filtering = filter !== "all" || query.trim() !== ""

  const displayed = useMemo(() => {
    const base = view === "topic" ? data : buildTimeTree(data, timeMode, now)
    if (!filtering) return base
    return filterTree(base, (t) => matchesFilter(t, filter, query, now)) ?? { ...base, children: [] }
  }, [data, view, timeMode, filter, query, now, filtering])
  const shownThreads = useMemo(() => collectThreads(displayed).length, [displayed])

  // ancestors() is [thread, topic, category, root] in the topic view; the time view has no
  // category ancestor, so the thread's own category field wins.
  const currentCategory =
    detail?.data.category ?? detail?.ancestors().reverse().slice(1, -1)[0]?.data.name ?? ""

  // Default the picker to wherever the thread currently sits each time one is opened.
  useEffect(() => {
    setMoveTo(currentCategory)
    setMoveError(null)
  }, [currentCategory])

  async function handleMove() {
    if (!detail || !moveTo || moveTo === currentCategory) return
    setMoving(true)
    setMoveError(null)
    try {
      await reclassifyThread(detail.data.id, moveTo)
      // The tree is rebuilt from scratch on new `data`, and this node belongs to the old one —
      // close the panel rather than leave it rendering a stale node.
      setDetail(null)
      await onReclassified?.()
    } catch (err) {
      setMoveError(err instanceof Error ? err.message : "Couldn't move this thread.")
    } finally {
      setMoving(false)
    }
  }

  useEffect(() => {
    if (!chartRef.current) return
    chartRef.current.innerHTML = ""

    const svg = d3
      .select(chartRef.current)
      .append("svg")
      .style("width", "100%")
      .style("height", "100%")
    const zoomLayer = svg.append("g")
    const linkLayer = zoomLayer.append("g").attr("class", "links")
    const nodeLayer = zoomLayer.append("g").attr("class", "nodes")

    const zoom = d3
      .zoom<SVGSVGElement, unknown>()
      .scaleExtent([0.3, 2])
      .on("zoom", (ev) => zoomLayer.attr("transform", ev.transform.toString()))
    svg.call(zoom)
    svg.on("mousedown.grab", () => chartRef.current?.classList.add("grabbing"))
    svg.on("mouseup.grab", () => chartRef.current?.classList.remove("grabbing"))

    const metaOf = (d: HierarchyNode): string => {
      if (d.data.type === "mail_thread") return threadMeta(d.data, now)
      if (d.data.type === "root") return ""
      const n = collectThreads(d.data).length
      return `${n} thread${n === 1 ? "" : "s"}`
    }
    const statusOf = (d: HierarchyNode): ThreadStatus =>
      d.data.type === "mail_thread" ? threadStatus(d.data, now).status : "none"
    const colorOf = (d: HierarchyNode): string | null => {
      const cat = categoryOf(d)
      return cat ? (colors.get(cat) ?? null) : null
    }
    const widthOf = (d: HierarchyNode): number => {
      const pad = colorOf(d) ? DOT_PAD : 0
      const title = truncate(d.data.name, 40).length * 7.2
      const meta = metaOf(d).length * 6.1
      return Math.max(150, Math.min(340, 18 + pad + Math.max(title, meta)))
    }

    function update(source: HierarchyNode, root: HierarchyNode) {
      const treeData = d3
        .tree<MailNode>()
        .nodeSize([NODE_HEIGHT + NODE_GAP_Y, LEVEL_WIDTH])(root as d3.HierarchyNode<MailNode>)
      const nodes = treeData.descendants() as HierarchyNode[]
      const links = treeData.links()

      nodes.forEach((d) => {
        d.y = d.depth * LEVEL_WIDTH
        d.w = widthOf(d)
      })

      const node = nodeLayer.selectAll<SVGGElement, HierarchyNode>("g.node").data(nodes, (d) => d.data.id)

      const nodeEnter = node
        .enter()
        .append("g")
        .attr("class", (d) => `node ${d.data.type} status-${statusOf(d)}`)
        .attr("transform", () => `translate(${source.y0 ?? 0},${source.x0 ?? 0})`)
        .style("opacity", 0)
        .on("click", (_ev, d) => {
          if (d.data.type === "mail_thread") {
            setDetail(d)
            return
          }
          toggleNode(d)
          update(d, root)
        })

      // Inline styles, not attributes: the stylesheet's class rules would otherwise win over
      // SVG presentation attributes. Category tints the fill, urgency owns the outline — two
      // separate channels, so neither colour has to mean two things.
      nodeEnter
        .append("rect")
        .attr("width", (d) => d.w ?? 150)
        .attr("height", NODE_HEIGHT)
        .attr("x", 0)
        .attr("y", -NODE_HEIGHT / 2)
        .style("fill", (d) => {
          const c = colorOf(d)
          return d.data.type === "mail_thread" && c ? hexToRgba(c, 0.13) : null
        })
        .style("stroke", (d) => {
          const urgent = STATUS_COLORS[statusOf(d)]
          if (urgent) return urgent
          const c = colorOf(d)
          if (!c) return null
          if (d.data.type === "mail_category") return c
          return d.data.type === "mail_topic" ? hexToRgba(c, 0.55) : null
        })
        .style("stroke-width", (d) => (STATUS_COLORS[statusOf(d)] ? "2.5px" : null))

      nodeEnter
        .filter((d) => colorOf(d) !== null)
        .append("circle")
        .attr("class", "cat-dot")
        .attr("r", 4.5)
        .attr("cx", 15)
        .attr("cy", 0)
        .style("fill", (d) => colorOf(d))

      nodeEnter
        .append("text")
        .attr("class", "title")
        .attr("x", (d) => (colorOf(d) ? 16 + DOT_PAD : 16))
        .attr("y", (d) => (metaOf(d) ? -7 : 2))
        .attr("dominant-baseline", "central")
        .text((d) => truncate(d.data.name, 40))

      nodeEnter
        .filter((d) => metaOf(d) !== "")
        .append("text")
        .attr("class", (d) => `meta status-${statusOf(d)}`)
        .attr("x", (d) => (colorOf(d) ? 16 + DOT_PAD : 16))
        .attr("y", 11)
        .attr("dominant-baseline", "central")
        .text((d) => metaOf(d))

      // Amber dot on threads the classifier wasn't sure about, so a wrong filing is visible
      // at a glance rather than only discoverable by opening every thread.
      nodeEnter
        .filter((d) => Boolean(d.data.needs_review))
        .append("circle")
        .attr("class", "review-flag")
        .attr("r", 4)
        .attr("cx", 8)
        .attr("cy", -NODE_HEIGHT / 2 + 8)

      nodeEnter
        .filter((d) => d.data.type === "mail_thread" && isNew(d.data, now))
        .append("circle")
        .attr("class", "new-dot")
        .attr("r", 4)
        .attr("cx", (d) => (d.w ?? 150) - 9)
        .attr("cy", -NODE_HEIGHT / 2 + 9)

      const toggleGroup = nodeEnter
        .filter((d) => d.data.type !== "mail_thread")
        .append("g")
        .attr("class", "toggle")
      toggleGroup.attr("transform", (d) => `translate(${(d.w ?? 150) + 14},0)`)
      toggleGroup.append("circle").attr("r", 10)
      toggleGroup.append("text").text((d) => (d.children ? "<" : d._children || d.data.children ? ">" : ""))

      const nodeUpdate = nodeEnter.merge(node)
      nodeUpdate
        .transition()
        .duration(DURATION)
        .attr("transform", (d) => `translate(${d.y},${d.x})`)
        .style("opacity", (d) => (d.data.type === "mail_thread" && isStale(d.data, now) ? 0.5 : 1))
      nodeUpdate
        .select(".toggle text")
        .text((d) =>
          d.children ? "<" : d._children || (d.data.children && d.data.children.length) ? ">" : "",
        )

      node
        .exit()
        .transition()
        .duration(DURATION)
        .attr("transform", () => `translate(${source.y},${source.x})`)
        .style("opacity", 0)
        .remove()

      const link = linkLayer.selectAll<SVGPathElement, d3.HierarchyLink<MailNode>>("path.link").data(
        links,
        (d) => (d.target as HierarchyNode).data.id,
      )

      const diagonal = (s: HierarchyNode, t: HierarchyNode) => {
        const sx = (s.y ?? 0) + (s.w ?? 150)
        const sy = s.x ?? 0
        const tx = t.y ?? 0
        const ty = t.x ?? 0
        const mx = (sx + tx) / 2
        return `M${sx},${sy} C${mx},${sy} ${mx},${ty} ${tx},${ty}`
      }

      const linkEnter = link
        .enter()
        .insert("path", "g")
        .attr("class", "link")
        .attr("d", () => {
          const o = { x: source.x0 ?? 0, y: source.y0 ?? 0, w: source.w } as HierarchyNode
          return diagonal(o, o)
        })

      linkEnter
        .merge(link)
        .transition()
        .duration(DURATION)
        .attr("d", (d) => diagonal(d.source as HierarchyNode, d.target as HierarchyNode))

      link
        .exit()
        .transition()
        .duration(DURATION)
        .attr("d", () => {
          const o = { x: source.x, y: source.y, w: source.w } as HierarchyNode
          return diagonal(o, o)
        })
        .remove()

      nodes.forEach((d) => {
        d.x0 = d.x
        d.y0 = d.y
      })
    }

    const root = d3.hierarchy(displayed) as HierarchyNode
    root.x0 = 0
    root.y0 = 0
    const top = (root.children ?? []) as HierarchyNode[]
    if (filtering) {
      // Searching or filtering: show every match rather than making the user dig for it.
      expandAll(root)
    } else if (view === "topic") {
      // Categories expanded, topics collapsed — matches brain/mail_tree.html.
      top.forEach((cat) => ((cat.children ?? []) as HierarchyNode[]).forEach(collapse))
    } else if (timeMode === "upcoming") {
      top.filter((b) => COLLAPSED_BUCKETS.has(b.data.id)).forEach(collapse)
    } else {
      // Newest month open with its newest day open; everything older folded away.
      top.forEach((month, i) => {
        const days = (month.children ?? []) as HierarchyNode[]
        if (i === 0) days.slice(1).forEach(collapse)
        else collapse(month)
      })
    }
    update(root, root)

    const svgNode = svg.node()
    if (svgNode) {
      svg.call(
        zoom.transform,
        d3.zoomIdentity.translate(60, svgNode.clientHeight / 2 + 20).scale(0.9),
      )
    }
  }, [displayed, view, timeMode, filtering, colors, now])

  const detailTimeline = detail?.data.type === "mail_thread" ? detail.data : null
  const legendCategories = [...colors.entries()].slice(0, 6)

  return (
    <div className="mail-mindmap-root">
      <div className="mail-mindmap-chart" ref={chartRef} />
      <div className="mail-mindmap-hint">scroll to zoom · drag to pan</div>
      <button className="mail-mindmap-download" onClick={handleDownload} disabled={downloading}>
        {downloading ? "Downloading…" : "⬇ Download tree (.md)"}
      </button>

      <div className="mail-mindmap-toolbar">
        <div className="seg" role="group" aria-label="Tree view">
          <button type="button" aria-pressed={view === "topic"} onClick={() => setView("topic")}>
            By topic
          </button>
          <button type="button" aria-pressed={view === "time"} onClick={() => setView("time")}>
            By time
          </button>
        </div>
        {view === "time" && (
          <div className="seg" role="group" aria-label="Group by">
            <button type="button" aria-pressed={timeMode === "upcoming"} onClick={() => setTimeMode("upcoming")}>
              Upcoming
            </button>
            <button type="button" aria-pressed={timeMode === "received"} onClick={() => setTimeMode("received")}>
              Received
            </button>
          </div>
        )}
        <div className="chips" role="group" aria-label="Filter threads">
          {FILTERS.map((f) => (
            <button
              key={f.id}
              type="button"
              aria-pressed={filter === f.id}
              className={`chip chip-${f.id}`}
              onClick={() => setFilter(f.id)}
            >
              {f.label}
            </button>
          ))}
        </div>
        <input
          type="search"
          className="search"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Search threads…"
          aria-label="Search threads"
        />
      </div>

      {shownThreads === 0 && (
        <div className="mail-mindmap-empty">
          {filtering ? "Nothing matches this filter." : "No threads yet."}
        </div>
      )}

      <div className="mail-mindmap-legend" aria-label="Legend">
        {LEGEND_STATUSES.map((s) => (
          <span key={s} className="item">
            <span className="ring" style={{ borderColor: STATUS_COLORS[s] ?? undefined }} />
            {STATUS_LABELS[s]}
          </span>
        ))}
        <span className="item">
          <span className="new" />
          New today
        </span>
        {legendCategories.map(([name, color]) => (
          <span key={name} className="item">
            <span className="dot" style={{ background: color }} />
            {name}
          </span>
        ))}
      </div>

      <div className="mail-mindmap-counts">
        <b>{counts.mail_category}</b> categories · <b>{counts.mail_topic}</b> topics ·{" "}
        <b>{counts.mail_thread}</b> threads
        <span className="hint"> · scroll to zoom · drag to pan</span>
      </div>

      <div className={`mail-mindmap-detail${detail ? " open" : ""}`}>
        {detail && (
          <>
            <button className="close" onClick={() => setDetail(null)}>
              &times;
            </button>
            {onAskAbout && (
              <button
                className="ask-btn"
                onClick={() => onAskAbout(`Tell me about "${detail.data.name}".`)}
              >
                Ask about this
              </button>
            )}
            <div className="path">
              {detail.data.category && detail.data.topic
                ? `${detail.data.category} › ${detail.data.topic}`
                : detail
                    .ancestors()
                    .reverse()
                    .slice(1, -1)
                    .map((n) => n.data.name)
                    .join(" › ")}
            </div>
            <h2>{detail.data.name}</h2>

            {detailTimeline && (
              <>
                <div className="lbl">Dates</div>
                {detailTimeline.events && detailTimeline.events.length > 0 ? (
                  <ul className="events">
                    {detailTimeline.events.map((event, i) => {
                      const info = threadStatus({ ...detailTimeline, events: [event] }, now)
                      const color = STATUS_COLORS[info.status]
                      return (
                        <li key={`${event.start}-${i}`}>
                          <span
                            className="status-chip"
                            style={color ? { color, borderColor: color } : undefined}
                          >
                            {eventStatusLabel(info.status, event.kind)}
                          </span>
                          <div className="event-text">
                            <b>{event.title}</b>
                            <span>
                              {event.kind === "deadline" ? "Deadline · " : ""}
                              {formatEventDate(event)}
                              {info.days !== null ? ` · ${relativeDays(info.days)}` : ""}
                              {event.location ? ` · ${event.location}` : ""}
                            </span>
                          </div>
                        </li>
                      )
                    })}
                  </ul>
                ) : (
                  <div className="muted">No dates mentioned in this thread.</div>
                )}
                {detailTimeline.last_received && (
                  <div className="received">
                    Received{" "}
                    {detailTimeline.first_received &&
                    detailTimeline.first_received.slice(0, 10) !== detailTimeline.last_received.slice(0, 10)
                      ? `${new Date(detailTimeline.first_received).toLocaleDateString()} – `
                      : ""}
                    {new Date(detailTimeline.last_received).toLocaleString(undefined, {
                      dateStyle: "medium",
                      timeStyle: "short",
                    })}
                    {detailTimeline.received_estimated ? " (approx.)" : ""}
                  </div>
                )}
              </>
            )}

            <div className="lbl">Category</div>
            {detail.data.needs_review && (
              <div className="review-note">
                Low confidence — check this category.
                {detail.data.classification?.llm_category &&
                detail.data.classification.llm_category !==
                  detail.data.classification.keyword_category ? (
                  <>
                    {" "}
                    The keyword rules said{" "}
                    <b>{detail.data.classification.keyword_category}</b>, the model said{" "}
                    <b>{detail.data.classification.llm_category}</b>.
                  </>
                ) : null}
              </div>
            )}
            <div className="move-row">
              {/* A datalist-backed input, not a <select>: the right category often doesn't
                  exist yet (that's how a thread got misfiled), and the API creates one on
                  demand. This lets the user pick an existing category or type a new one,
                  without pulling in a combobox dependency. */}
              <input
                list="mail-mindmap-categories"
                value={moveTo}
                onChange={(e) => setMoveTo(e.target.value)}
                aria-label="Move to category"
                placeholder="Category…"
              />
              <datalist id="mail-mindmap-categories">
                {categoryNames.map((name) => (
                  <option key={name} value={name} />
                ))}
              </datalist>
              <button
                className="move-btn"
                disabled={moving || !moveTo || moveTo === currentCategory}
                onClick={handleMove}
              >
                {moving ? "Moving…" : "Move"}
              </button>
            </div>
            {moveError && <div className="move-error">{moveError}</div>}

            <div className="lbl">Summary</div>
            <div className="summary">{detail.data.summary || "(no summary)"}</div>
            {detail.data.body && (
              <>
                <div className="lbl">Full content</div>
                <div className="body">{detail.data.body}</div>
              </>
            )}
            {detail.data.source_uids && detail.data.source_uids.length > 0 && (
              <>
                <div className="lbl">Source emails</div>
                <div className="uids">
                  {detail.data.source_uids.map((u) => (
                    <span className="uid" key={u}>
                      uid {u}
                    </span>
                  ))}
                </div>
              </>
            )}
          </>
        )}
      </div>
    </div>
  )
}
