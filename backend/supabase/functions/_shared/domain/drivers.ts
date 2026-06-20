// backend/supabase/functions/_shared/domain/drivers.ts
// MBI Scoring Engine — Top-2 Driver Selection
// Version: 1.4 | v1.7 domain: baseline-only driver_2 fallback (Non-Negotiable #4).
//   When today's data supplies no second metric, driver_2 may resolve from a metric
//   the user has a baseline pattern for (no fresh reading today), flagged driver_2_stale.
// Version: 1.3 | sleep_continuity replaces sleep_efficiency; spo2 added as physiological (D13)

import type { Baseline, MetricDeviation, MetricName } from "./contracts.ts";
import { METRIC_WEIGHTS } from "./deviation.ts";

const PHYSIOLOGICAL: MetricName[] = [
  "hrv", "resting_hr", "respiratory_rate", "sleep_duration", "sleep_continuity", "spo2",
];

function isPhysiological(metric: MetricName): boolean {
  return PHYSIOLOGICAL.includes(metric);
}

// All weighted metrics (METRIC_WEIGHTS > 0), highest weight first. The baseline-only
// driver_2 fallback (v1.7) walks this to pick the most meaningful second driver from
// the user's history when today's data supplies no second metric.
const WEIGHTED_METRICS_DESC: MetricName[] = (Object.keys(METRIC_WEIGHTS) as MetricName[])
  .filter((m) => METRIC_WEIGHTS[m] > 0)
  .sort((a, b) => METRIC_WEIGHTS[b] - METRIC_WEIGHTS[a]);

// MetricName → the Baseline field holding that metric's 7-day average. Explicit map,
// not a dynamic `baseline[`${m}_avg`]` index (that typed-index cast was a prior bug,
// eb7f25a). Metrics absent here (e.g. distance) have no baseline average and can never
// be a fallback driver — which is correct, they also carry zero weight.
const METRIC_BASELINE_FIELD: Partial<Record<MetricName, keyof Baseline>> = {
  hrv:              "hrv_avg",
  resting_hr:       "resting_hr_avg",
  respiratory_rate: "respiratory_rate_avg",
  sleep_duration:   "sleep_duration_avg",
  sleep_continuity: "sleep_continuity_avg",
  steps:            "steps_avg",
  active_minutes:   "active_minutes_avg",
  spo2:             "spo2_avg",
  stand_hours:      "stand_hours_avg",
  resting_energy:   "resting_energy_avg",
};

// True when the user has a computed baseline average for `metric` — i.e. the metric
// has recent history even if it produced no fresh reading today.
function hasBaseline(baseline: Baseline, metric: MetricName): boolean {
  const field = METRIC_BASELINE_FIELD[metric];
  return field != null && baseline[field] != null;
}

export function selectTopDrivers(deviations: MetricDeviation[], baseline: Baseline | null): {
  driver_1: MetricName;
  driver_2: MetricName | null;
  driver_2_stale: boolean;
} {
  const scored = deviations
    .filter((d) => d.weight > 0)
    .map((d) => ({
      metric: d.metric,
      score:  Math.abs(d.deviation) * d.weight,
      physio: isPhysiological(d.metric),
    }))
    .sort((a, b) => {
      if (b.score !== a.score) return b.score - a.score;
      if (a.physio !== b.physio) return a.physio ? -1 : 1;
      return 0;
    });

  const flagged = scored.filter((s) => s.score > 0);
  const pool = flagged.length >= 1 ? flagged : scored;

  const driver_1 = pool[0]?.metric ?? "hrv";
  // Select driver_2 as the next distinct metric — never duplicate driver_1.
  // Fall back to the full scored list (all weighted metrics with today's data) first.
  let driver_2: MetricName | null = pool.find((s, i) => i > 0 && s.metric !== driver_1)?.metric
    ?? scored.find((s) => s.metric !== driver_1)?.metric
    ?? null;

  // v1.7 baseline-only fallback (Non-Negotiable #4): if today's data supplied no second
  // metric, draw driver_2 from a metric the user has a baseline pattern for (no fresh
  // reading today). Flagged stale so narration frames it as a steady pattern, not movement.
  // If no metric qualifies (genuine zero-baseline edge), driver_2 stays null — an
  // accepted, documented limit, gated by D12 (such users see no score explanation anyway).
  let driver_2_stale = false;
  if (driver_2 === null && baseline) {
    const fallback = WEIGHTED_METRICS_DESC.find(
      (m) => m !== driver_1 && hasBaseline(baseline, m),
    );
    if (fallback) {
      driver_2 = fallback;
      driver_2_stale = true;
    }
  }

  return { driver_1, driver_2, driver_2_stale };
}
