// packages/domain/index.ts
// MBI Scoring Engine — Public API
// Version: 1.4 | Baseline Range Architecture v1.0 (May 2026)

export * from "./contracts.ts";
export { computeBaseline } from "./baseline.ts";
export { computeDeviations, METRIC_WEIGHTS } from "./deviation.ts";
export { scoreDay, getScoreBand, selectNudgeDomain } from "./scoring.ts";
export { selectTopDrivers } from "./drivers.ts";
export { computeFailState } from "./failstates.ts";
export {
  computeValidDays,
  computeTrustState,
  computeHRV7dRollingAvg,
  computeRangePercentiles,
  classifyZone,
  classifyDriverZone,
} from "./range.ts";
// RangePercentiles and ValidDayCounts are range-specific interfaces not in contracts
export type { RangePercentiles, ValidDayCounts } from "./range.ts";
// ZoneState and RangeTrustState are already exported via `export * from "./contracts.ts"`
