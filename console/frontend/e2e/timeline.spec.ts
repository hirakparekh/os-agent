import { type Page, expect, test } from "@playwright/test"

import { clickMapNode, login, openMailMap, seedBrain, signIn } from "./helpers"

// e2e/support/seed.py dates every thread relative to today:
//   Accenture Off-Campus Drive 2026 — received 3h ago, online-assessment deadline in 2 days
//   Yoga Competition 2026           — received 2 days ago, event in 10 days
//   Guest Lecture on Compilers      — received 40 days ago, assignment deadline 4 days ago
const ACCENTURE = "Accenture Off-Campus Drive 2026"
const YOGA = "Yoga Competition 2026"
const COMPILERS = "Guest Lecture on Compilers"

const thread = (page: Page, title: string) => page.locator(".node.mail_thread", { hasText: title })
const bucket = (page: Page, name: string) =>
  page.locator(".node.time_bucket", { has: page.locator("text.title", { hasText: name }) })

async function openTimeView(page: Page) {
  await page.getByRole("button", { name: "By time" }).click()
  await expect(page.locator(".node.time_bucket").first()).toBeVisible()
}

test.describe("time view of the mail tree", () => {
  test.beforeEach(async ({ page }) => {
    const { userId } = await login()
    seedBrain(userId)
    await signIn(page)
    await openMailMap(page)
  })

  test("Upcoming groups threads by how soon they're due, with urgency colours", async ({ page }) => {
    await openTimeView(page)

    await expect(bucket(page, "Overdue")).toBeVisible()
    await expect(bucket(page, "This week")).toBeVisible()
    await expect(bucket(page, "Next week")).toBeVisible()

    await expect(thread(page, COMPILERS)).toHaveClass(/status-overdue/)
    await expect(thread(page, COMPILERS)).toContainText("Overdue · was due")
    await expect(thread(page, ACCENTURE)).toHaveClass(/status-soon/)
    await expect(thread(page, ACCENTURE)).toContainText("in 2 days")
    await expect(thread(page, YOGA)).toHaveClass(/status-upcoming/)
    // Only the mail from the last 24h carries the "new" marker.
    await expect(thread(page, ACCENTURE).locator("circle.new-dot")).toHaveCount(1)
    await expect(thread(page, YOGA).locator("circle.new-dot")).toHaveCount(0)
  })

  test("Received groups threads by when they arrived, newest first", async ({ page }) => {
    await openTimeView(page)
    await page.getByRole("button", { name: "Received", exact: true }).click()

    // The newest day is open by default, so this morning's mail is right there.
    await expect(thread(page, ACCENTURE)).toBeVisible()
    await expect(thread(page, ACCENTURE)).toContainText("Due")
  })

  test("filter chips narrow the tree to matching threads", async ({ page }) => {
    await page.getByRole("button", { name: "Overdue", exact: true }).click()
    await expect(thread(page, COMPILERS)).toBeVisible()
    await expect(page.locator(".node.mail_thread")).toHaveCount(1)

    await page.getByRole("button", { name: "Due in 7 days" }).click()
    await expect(thread(page, ACCENTURE)).toBeVisible()
    await expect(page.locator(".node.mail_thread")).toHaveCount(1)

    await page.getByRole("button", { name: "All", exact: true }).click()
    await page.getByLabel("Search threads").fill("yoga")
    await expect(thread(page, YOGA)).toBeVisible()
    await expect(page.locator(".node.mail_thread")).toHaveCount(1)

    await page.getByLabel("Search threads").fill("zzz-nothing")
    await expect(page.getByText("Nothing matches this filter.")).toBeVisible()
  })

  test("a thread's detail panel lists its dates and where it's filed", async ({ page }) => {
    await openTimeView(page)
    await clickMapNode(page, "mail_thread", ACCENTURE)

    const panel = page.locator(".mail-mindmap-detail.open")
    await expect(panel).toBeVisible()
    await expect(panel.getByText("Placements › Accenture")).toBeVisible()
    await expect(panel.getByText("Online assessment")).toBeVisible()
    await expect(panel.getByText("Due soon", { exact: true })).toBeVisible()
    await expect(panel.getByText(/Deadline · .* · in 2 days/)).toBeVisible()
    // Reclassifying still knows the real category even though the time view has no category
    // ancestor for this node.
    await expect(panel.getByLabel("Move to category")).toHaveValue("Placements")
  })
})
