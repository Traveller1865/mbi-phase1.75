// backend/supabase/functions/_shared/domain/drivers.ts
// MBI Scoring Engine — Top-2 Driver Selection
// Version: 1.3 | sleep_continuity replaces sleep_efficiency; spo2 added as physiological (D13)

import type { MetricDeviation, MetricName } from "./contracts.ts";

const PHYSIOLOGICAL: MetricName[] = [
  "hrv", "resting_hr", "respiratory_rate", "sleep_duration", "sleep_continuity", "spo2",
];

function isPhysiological(metric: MetricName): boolean {
  return PHYSIOLOGICAL.includes(metric);
}

export function selectTopDrivers(deviations: MetricDeviation[]): {
  driver_1: MetricName;
  driver_2: MetricName | null;
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
  // Fall back to the full scored list (all weighted metrics) before returning null,
  // so high-scoring days with a single flagged metric still produce a driver_2.
  const driver_2 = pool.find((s, i) => i > 0 && s.metric !== driver_1)?.metric
    ?? scored.find(s => s.metric !== driver_1)?.metric
    ?? null;

  return { driver_1, driver_2 };
}
