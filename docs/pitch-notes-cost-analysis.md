# Cost analysis — INR framing (for VP/VC pitch)

Reference notes from live token-usage testing, kept for reuse when building out the pitch further.

## Real measured token usage (liquid/lfm-2.5-2.6b:free, via OpenRouter, real data)

| Call | Prompt (input) tokens | Completion (output) tokens | Of which reasoning |
|---|---|---|---|
| `classify_email` | 830 | 877 | 835 (95%) |
| `merge_or_create_thread` | 1,073 | 2,857 | 2,056 (72%) |
| `ask_mail` (1 question) | 10,472 | 1,217 | 1,109 (91%) |

- 1 email fully ingested = classify + merge = 1,903 input / 3,734 output tokens.
- 1 question answered = 10,472 input / 1,217 output tokens.
- Tried swapping to a "non-reasoning" free model (nvidia/nemotron-3.5-lightning:free) to cut reasoning overhead — made it *worse* (merge call: 6,098 reasoning tokens vs. 2,056 originally). Dead end, don't repeat.
- Excluding reasoning tokens from the total doesn't meaningfully help the one comparison that matters (ask_mail vs. the 2,000–6,000 token industry RAG benchmark) — the ask_mail cost is dominated by prompt size (the full-mailbox overview), not completion/reasoning. Tried, confirmed it doesn't flip the outcome, abandoned per the "if it doesn't work, skip it" rule.

## $ → ₹ cost, real pricing basis

- Pricing reference: GPT-4o-mini, $0.15/1M input tokens, $0.60/1M output tokens (cited, 2026).
- Exchange rate used: ₹95.6 / $1 (USD/INR, 2026-09-12, cited).
- Per email processed: $0.00253 → **₹0.24**
- Per question answered: $0.00230 → **₹0.22**

## Scaled, presentable numbers

| Scenario | Cost |
|---|---|
| 100 emails processed | ₹24 |
| 1,000 emails processed | ₹242 |
| 100 questions answered | ₹22 |
| 1,000 emails + 20 questions | ₹246 |
| 1,000 emails + 50 questions | ₹253 |
| 1,000 emails + 100 questions | ₹264 |

**Headline number to lead with:** ~₹250 for a full month of mail (1,000 emails) plus regular daily chat use (50 questions) — "less than a dinner out." Total barely moves with question count since email volume dominates, so it survives a "why that number of questions" pushback.

**Live-demo move:** ask the judge how many emails/week they get, multiply live by ₹0.24/email in front of them. Much stronger than a static slide number.

**Caveat to keep ready:** per-question cost (₹0.22) is calculated at today's inbox size (14 threads) — it grows as the mailbox grows, since `ask_mail`'s prompt includes a full mailbox overview, not a bounded top-k retrieval. If pushed on "does this hold at 10,000 emails," the honest answer is "not at this exact price — that's a known, fixable scaling knob, not fixed yet."

## Status

This is currently **one point/slide** in the VP/VC product pitch (`docs/product-pitch.html`). Not yet added to the deck — next step is wiring it in as a section.
