# Unit Tests — `_shared/domain`

Unit tests for the **canonical** domain logic. They import from `../*.ts`, so they run
against the exact code that deploys (no copy, no sync, no equivalence assumption).

**Runner:** `deno test backend/supabase/functions/_shared/domain/__tests__/` (root script: `test:domain`).

## Binding rule for this suite
Every expected value traces to a **documented, authoritative rule** — not to current
code output and not to code comments. A test must be able to fail when the code is wrong.

## Source traceability

| Test group | Traces to |
|---|---|
| **Score bands** (v1.6: 80+ Thriving / 70–79 Recovering / 40–69 Drifting / <40 Redline) | Founder approval (2026-06) + Canonical Backend Architecture v1.2 + `contracts.ts` v1.6 `ScoreBand` |
| **Decline signal** (Yellowline momentum: ≥70 & ≥5pt decline vs 5–7d ref, ≥5 scored-day gate, hysteresis) | Yellowline Build Handoff v1.0 §3 + `contracts.ts` v1.6 `DeclineSignal` |
| **Determinism** (identical inputs → identical outputs) | Non-Negotiable #1 |
| **Within-user primacy** (personal baselines, not population constants) | Non-Negotiable #2 |
| **Provisional / null-baseline** (no synthetic score) | D12 (four-tier confidence model) |
| **Null `driver_2` path** | `contracts.ts` `ScoringResult.driver_2: MetricName \| null` + driver-selection fix rationale |

## HELD — pending the consolidated v1.5 Logic Registry
The numeric **deviation threshold** groups are intentionally **not** in this suite:
HRV, RHR, respiratory rate, steps, active-minutes, sleep duration, sleep continuity,
SpO2, stand hours — including the three-layer reserve-flag cutoffs.

These thresholds are cited in code as `SoT §x` / `Dx`, but the consolidated v1.5 Logic
Registry they trace to **does not yet exist in version-controlled form**. Tracing them to
code comments was explicitly declined (it would make the tests circular). They become a
follow-on work item once the Registry is produced and committed.

> Repo gap (logged to the register): the Logic Registry / scoring spec is not committed
> alongside the code it governs. It should live in the repo so threshold tests can trace to it.
