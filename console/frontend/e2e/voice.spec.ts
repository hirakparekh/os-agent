import { type Page, expect, test } from "@playwright/test"

import { E2E } from "../playwright.config"
import { login, resetChats, seedBrain, signIn } from "./helpers"

// The fake Sarvam (e2e/support/fake_sarvam.py) always "hears" this, whatever the fake mic sends.
const HEARD = "What did Accenture say?"
const STUB = /STUBBED ANSWER:/

const thread = (page: Page) => page.getByTestId("chat-thread")

async function spokenTexts(): Promise<string[]> {
  const res = await fetch(`${E2E.sarvamUrl}/spoken`)
  return (await res.json()) as string[]
}

async function speakQuestion(page: Page): Promise<void> {
  await page.getByRole("button", { name: "Speak your question" }).click()
  await expect(page.getByText("Listening…")).toBeVisible()
  await page.waitForTimeout(800) // let the fake mic produce some audio
  await page.getByRole("button", { name: "Stop recording" }).click()
  await expect(page.getByPlaceholder("Ask a question…")).toHaveValue(HEARD, { timeout: 15_000 })
}

test.describe("voice chat", () => {
  test.beforeEach(async () => {
    const { token, userId } = await login()
    seedBrain(userId)
    await resetChats(token)
    await fetch(`${E2E.sarvamUrl}/spoken`, { method: "DELETE" })
  })

  test("a spoken question is transcribed into the composer, not auto-sent", async ({ page }) => {
    await signIn(page)
    await page.getByRole("button", { name: "New chat", exact: true }).click()
    await speakQuestion(page)
    // Still editable and unsent: the thread shows the empty state, no user bubble yet.
    await expect(thread(page).getByText(HEARD, { exact: true })).toHaveCount(0)

    await page.getByPlaceholder("Ask a question…").press("Enter")
    await expect(thread(page).getByText(STUB)).toBeVisible({ timeout: 30_000 })
  })

  test("cancelling a recording discards it", async ({ page }) => {
    await signIn(page)
    await page.getByRole("button", { name: "Speak your question" }).click()
    await expect(page.getByText("Listening…")).toBeVisible()
    await page.getByRole("button", { name: "Cancel" }).click()
    await expect(page.getByPlaceholder("Ask a question…")).toHaveValue("")
  })

  test("an answer can be read aloud on demand", async ({ page }) => {
    await signIn(page)
    await page.getByRole("button", { name: "New chat", exact: true }).click()
    const composer = page.getByPlaceholder("Ask a question…")
    await composer.fill("Anything from Accenture?")
    await composer.press("Enter")
    await expect(thread(page).getByText(STUB)).toBeVisible({ timeout: 30_000 })
    expect(await spokenTexts()).toEqual([])

    await thread(page).getByRole("button", { name: "Read aloud" }).click()
    await expect.poll(spokenTexts).toHaveLength(1)
    expect((await spokenTexts())[0]).toMatch(STUB)
  })

  test("with 'Read answers aloud' on, new answers are spoken automatically", async ({ page }) => {
    await signIn(page)
    await page.getByRole("button", { name: "New chat", exact: true }).click()
    await page.getByRole("button", { name: "Voice settings" }).click()
    await page.getByLabel("Read answers aloud").check()
    await page.keyboard.press("Escape")

    const composer = page.getByPlaceholder("Ask a question…")
    await composer.fill("Anything from Accenture?")
    await composer.press("Enter")
    await expect(thread(page).getByText(STUB)).toBeVisible({ timeout: 30_000 })
    await expect.poll(spokenTexts).toHaveLength(1)
  })
})
