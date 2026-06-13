// _shared/domain/ontology/pathway.ts
// Ontology Engine v1 — Pathway Classification + Confidence Gate
// Ontology version: phase1_75-v1.0
//
// INVARIANT: All classification is deterministic. No LLM, no inference.
// condition_class is INTERNAL ONLY — never rendered verbatim in any iOS view.

import type {
  ActivationResult,
  PathwayClassification,
  PathwayKey,
  PathwayState,
  ConditionClass,
  TrustState,
  EvaluationContext,
} from "./types.ts";

// ─────────────────────────────────────────
// PATHWAY → NODE MAPPINGS
// ─────────────────────────────────────────

const PATHWAY_NODES: Record<PathwayKey, string[]> = {
  autonomic: ["low_hrv", "elevated_resting_hr", "autonomic_dysfunction", "sympathetic_dominance"],
  sleep:     ["poor_sleep_quality", "circadian_disruption", "sleep_fragmentation"],
  metabolic: ["physical_inactivity", "recovery_load_imbalance", "sustained_recovery_deficit"],
};

const PATHWAY_PROTECTIVE: Record<PathwayKey, string> = {
  autonomic: "quality_sleep",
  sleep:     "quality_sleep",
  metabolic: "daily_exercise",
};

// ─────────────────────────────────────────
// TRAJECTORY LABELS (deterministic, internal)
// ─────────────────────────────────────────

const TRAJECTORY_LABELS: Record<PathwayKey, Record<Exclude<PathwayState, "CALM">, string>> = {
  autonomic: { ELEVATED: "Autonomic load present",   FLAGGED: "Autonomic strain sustained"  },
  sleep:     { ELEVATED: "Sleep pattern disrupted",  FLAGGED: "Sleep deficit compounding"   },
  metabolic: { ELEVATED: "Recovery deficit emerging",FLAGGED: "Metabolic load building"     },
};

// ─────────────────────────────────────────
// CLASSIFY ONE PATHWAY
// ─────────────────────────────────────────

export function classifyPathway(
  pathwayKey: PathwayKey,
  activations: Map<string, ActivationResult>,
  ctx: EvaluationContext,
): PathwayClassification {
  const activeNodes = PATHWAY_NODES[pathwayKey].filter(k => activations.get(k)?.is_active);
  const protectiveActive = activations.get(PATHWAY_PROTECTIVE[pathwayKey])?.is_active ?? false;

  // Raw state before protective attenuation
  let rawState: PathwayState;
  if (activeNodes.length === 0)      rawState = "CALM";
  else if (activeNodes.length === 1) rawState = "ELEVATED";
  else                               rawState = "FLAGGED";

  // Protective attenuation: one step down per active protective node (binary in v1)
  let state = rawState;
  if (protectiveActive && state === "FLAGGED")   state = "ELEVATED";
  else if (protectiveActive && state === "ELEVATED") state = "CALM";

  if (state === "CALM") {
    const cg = computeConfidenceGate(ctx, pathwayKey, "CALM", 0);
    return {
      pathway_key:      pathwayKey,
      state:            "CALM",
      trajectory_label: null,
      condition_class:  null,
      escalation_level: 0,
      confidence_gate:  cg.confidence_gate,
      days_in_pattern:  0,
      activating_nodes: [],
      _trustFactor:     cg.trust_factor,
      _depthFactor:     cg.depth_factor,
      _stabilityFactor: cg.stability_factor,
    };
  }

  const activatingNodes = activeNodes.map(k => ({
    node_key:            k,
    activation_strength: activations.get(k)?.activation_strength ?? 0,
  }));

  const trajectoryLabel = TRAJECTORY_LABELS[pathwayKey][state];
  const conditionClass  = assignConditionClass(pathwayKey, state, activations);
  const daysInPattern   = computeDaysInPattern(ctx, pathwayKey, state);
  const escalationLevel = computeEscalationLevel(state, daysInPattern, conditionClass);
  const cg              = computeConfidenceGate(ctx, pathwayKey, state, daysInPattern);

  return {
    pathway_key:      pathwayKey,
    state,
    trajectory_label: trajectoryLabel,
    condition_class:  conditionClass,
    escalation_level: escalationLevel,
    confidence_gate:  cg.confidence_gate,
    days_in_pattern:  daysInPattern,
    activating_nodes: activatingNodes,
    _trustFactor:     cg.trust_factor,
    _depthFactor:     cg.depth_factor,
    _stabilityFactor: cg.stability_factor,
  };
}

// ─────────────────────────────────────────
// CONDITION CLASS ASSIGNMENT (§4.5)
// ─────────────────────────────────────────

function assignConditionClass(
  pathway: PathwayKey,
  state: PathwayState,
  activations: Map<string, ActivationResult>,
): ConditionClass | null {
  if (state === "CALM") return null;

  // load_accumulating: recovery_load_imbalance ACTIVE 3+ consecutive days AND sustained_recovery_deficit ACTIVE
  const rliDays    = activations.get("recovery_load_imbalance")?.days_active ?? 0;
  const cfActive   = activations.get("sustained_recovery_deficit")?.is_active ?? false;
  if (rliDays >= 3 && cfActive) return "load_accumulating";

  // recovery_deficit: low_hrv OR autonomic_dysfunction ACTIVE 5+ days within last 7
  const lowHRVDays = activations.get("low_hrv")?.days_active ?? 0;
  const adDays     = activations.get("autonomic_dysfunction")?.days_active ?? 0;
  if (lowHRVDays >= 5 || adDays >= 5) return "recovery_deficit";

  // autonomic_strain: sympathetic_dominance ACTIVE 4+ consecutive days
  const symDays = activations.get("sympathetic_dominance")?.days_active ?? 0;
  if (symDays >= 4) return "autonomic_strain";

  // metabolic_stress_early: physical_inactivity ACTIVE 5+ of last 7 days AND (low_hrv OR elevated_rhr ACTIVE 3+ of those)
  const inactDays = activations.get("physical_inactivity")?.days_active ?? 0;
  const elevRHRDays = activations.get("elevated_resting_hr")?.days_active ?? 0;
  if (inactDays >= 5 && (lowHRVDays >= 3 || elevRHRDays >= 3)) return "metabolic_stress_early";

  // sleep_debt_compounding: poor_sleep_quality ACTIVE 4+ of last 7 days AND (sleep_fragmentation 2+ OR sustained_recovery_deficit ACTIVE)
  const psDays  = activations.get("poor_sleep_quality")?.days_active ?? 0;
  const sfDays  = activations.get("sleep_fragmentation")?.days_active ?? 0;
  if (psDays >= 4 && (sfDays >= 2 || cfActive)) return "sleep_debt_compounding";

  return null;
}

// ─────────────────────────────────────────
// ESCALATION LEVEL (§4.4)
// ─────────────────────────────────────────

function computeEscalationLevel(
  state: PathwayState,
  daysInPattern: number,
  conditionClass: ConditionClass | null,
): number {
  if (state === "CALM")    return 0;
  if (state === "ELEVATED") return 1;
  // FLAGGED
  if (daysInPattern >= 14) return 3;
  if (conditionClass === "autonomic_strain" && daysInPattern >= 10) return 3;
  return 2;
}

// ─────────────────────────────────────────
// DAYS IN PATTERN (consecutive non-CALM days before today)
// ─────────────────────────────────────────

function computeDaysInPattern(
  ctx: EvaluationContext,
  pathwayKey: PathwayKey,
  currentState: PathwayState,
): number {
  if (currentState === "CALM") return 0;
  // Count consecutive non-CALM days for this pathway immediately before today
  const prior = ctx.priorPathways30d
    .filter(p => p.pathway_key === pathwayKey)
    .sort((a, b) => b.classification_date.localeCompare(a.classification_date)); // descending
  let streak = 0;
  let prevDate: Date | null = null;
  const todayMs = new Date(ctx.date).getTime();
  for (const row of prior) {
    if (row.state === "CALM") break;
    const d = new Date(row.classification_date);
    if (prevDate === null) {
      // Must be yesterday or today
      const gap = Math.round((todayMs - d.getTime()) / 86_400_000);
      if (gap > 1) break;
      streak = 1;
      prevDate = d;
    } else {
      const gap = Math.round((prevDate.getTime() - d.getTime()) / 86_400_000);
      if (gap !== 1) break;
      streak++;
      prevDate = d;
    }
  }
  return streak + 1; // +1 for today
}

// ─────────────────────────────────────────
// CONFIDENCE GATE (§5)
// confidence_gate = trust_factor × depth_factor × stability_factor
// ─────────────────────────────────────────

interface ConfidenceGateResult {
  confidence_gate: number;
  trust_factor: number;
  depth_factor: number;
  stability_factor: number;
}

function computeConfidenceGate(
  ctx: EvaluationContext,
  pathwayKey: PathwayKey,
  state: PathwayState,
  daysInPattern: number,
): ConfidenceGateResult {
  if (state === "CALM") {
    return { confidence_gate: 1.0, trust_factor: 1.0, depth_factor: 1.0, stability_factor: 1.0 };
  }

  const trust_factor     = trustFactorFromState(ctx.trustState);
  const depth_factor     = depthFactorFromDays(daysInPattern);
  const stability_factor = stabilityFactorFromHistory(ctx, pathwayKey);
  const confidence_gate  = Math.round(trust_factor * depth_factor * stability_factor * 100) / 100;

  return { confidence_gate, trust_factor, depth_factor, stability_factor };
}

function trustFactorFromState(trust: TrustState): number {
  switch (trust) {
    case "establishing": return 0.0;
    case "calibrating":  return 0.0;
    case "provisional":  return 0.5;
    case "trusted":      return 0.8;
    case "established":  return 1.0;
  }
}

function depthFactorFromDays(days: number): number {
  if (days < 7)   return 0.3;
  if (days < 14)  return 0.6;
  if (days < 30)  return 0.85;
  return 1.0;
}

function stabilityFactorFromHistory(
  ctx: EvaluationContext,
  pathwayKey: PathwayKey,
): number {
  const last14 = ctx.priorPathways30d
    .filter(p => p.pathway_key === pathwayKey)
    .filter(p => {
      const d = new Date(p.classification_date);
      const today = new Date(ctx.date);
      return (today.getTime() - d.getTime()) / 86_400_000 <= 14;
    });
  if (last14.length < 2) return 1.0; // not enough history — assume stable
  let changes = 0;
  for (let i = 1; i < last14.length; i++) {
    if (last14[i].state !== last14[i - 1].state) changes++;
  }
  if (changes >= 3)  return 0.4;
  if (changes >= 1)  return 0.7;
  return 1.0;
}
