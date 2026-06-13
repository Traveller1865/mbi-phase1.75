// packages/domain/drivers.ts
// MBI Scoring Engine — Top-2 Driver Selection
// Version: 1.1 | Always exactly 2 drivers. Never 1. Never 3.

import type { MetricDeviation, MetricName } from "./contracts.ts";

// Physiological signals ranked above behavioral for tiebreaking (SoT §9)
const PHYSIOLOGICAL: MetricName[] = ["hrv", "resting_hr", "respiratory_rate", "sleep_duration", "sleep_efficiency"];

function isPhysiological(metric: MetricName): boolean {
  return PHYSIOLOGICAL.includes(metric);
}

/**
 * Rank metrics by weighted deviation magnitude.
 * Physiological > Behavioral on tiebreak.
 * Always returns exactly 2 driver names.
 */
export function selectTopDrivers(deviations: MetricDeviation[]): {
  driver_1: MetricName;
  driver_2: MetricName;
} {
  // Score each metric: weighted deviation magnitude
  const scored = deviations
    .filter((d) => d.weight > 0)
    .map((d) => ({
      metric: d.metric,
      score: Math.abs(d.deviation) * d.weight,
      physio: isPhysiological(d.metric),
    }))
    .sort((a, b) => {
      // Primary: higher score first
      if (b.score !== a.score) return b.score - a.score;
      // Tiebreak: physiological before behavioral
      if (a.physio !== b.physio) return a.physio ? -1 : 1;
      return 0;
    });

  // If we have 2+ flagged metrics, take top 2
  const flagged = scored.filter((s) => s.score > 0);
  if (flagged.length >= 2) {
    return { driver_1: flagged[0].metric, driver_2: flagged[1].metric };
  }

  // Fallback: use 2 largest deviations from baseline even if within normal range (SoT §9)
  if (scored.length >= 2) {
    return { driver_1: scored[0].metric, driver_2: scored[1].metric };
  }

  // Edge case: fewer than 2 metrics available — default to physiological pair
  return { driver_1: "hrv", driver_2: "resting_hr" };
}
