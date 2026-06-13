// packages/domain/index.ts
// MBI Scoring Engine — Public API
// Version: 1.1

export * from "./contracts.ts";
export { computeBaseline } from "./baseline.ts";
export { computeDeviations, METRIC_WEIGHTS } from "./deviation.ts";
export { scoreDay, getScoreBand, selectNudgeDomain } from "./scoring.ts";
export { selectTopDrivers } from "./drivers.ts";
export { computeFailState } from "./failstates.ts";
