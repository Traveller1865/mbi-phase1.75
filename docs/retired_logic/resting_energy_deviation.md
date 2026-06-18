# Retired logic — `resting_energy` deviation

**Status:** RETIRED (not active in the live scoring engine).
**Retired per:** D13 — `resting_energy` set to **weight 0** in the live `_shared/domain/deviation.ts` (v1.4), so it no longer contributes to the score. The dedicated deviation function below was therefore not carried into `_shared`.
**Provenance:** sourced verbatim from `packages/domain/deviation.ts` (v1.2, "H-01: Tier 1 metric expansion") before `packages/domain` was deleted in the Phase C/D consolidation (2026-06).
**Why archived:** this was the one piece of genuinely unique logic that lived only in `packages/domain`. It is preserved here (in addition to the frozen 1.5 archive repo) so the thresholds are findable if `resting_energy` scoring is ever reinstated.

## The function

```ts
// RESTING ENERGY — Weight 1× (H-01 / D3 Activity)
// Metabolic suppression signal.
// Uses personal baseline only — no universal guardrail
// (highly individual: varies by body composition, age, sex).
// Mild: >15% below personal baseline
// Hard: >30% below personal baseline
// Missing baseline → no deviation (cannot judge without context).
function deviateRestingEnergy(value: number | null | undefined, baseline: Baseline): DeviationState {
  if (value == null || baseline.resting_energy_avg == null) return 0;
  const pctBelow = (baseline.resting_energy_avg - value) / baseline.resting_energy_avg;
  if (pctBelow > 0.30) return -2;
  if (pctBelow >= 0.15) return -1;
  return 0;
}
```

## Associated weight (also retired)
In `packages/domain` v1.2, `METRIC_WEIGHTS.resting_energy = 1`. In live `_shared` v1.4 it is `0`
(retained in the array so the metric still appears in the deviations output, but with no scoring effect).

## If reinstated
1. Restore the function into `_shared/domain/deviation.ts` and wire it in `computeDeviations`.
2. Set `METRIC_WEIGHTS.resting_energy` to a non-zero weight.
3. Add threshold unit tests traced to the (then-current) Logic Registry entry — do not trace to this archive.
