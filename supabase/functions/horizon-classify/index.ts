// supabase/functions/horizon-classify/index.ts
// MBI Phase 2 — Horizon Ontology Classification Engine
//
// Triggered from iOS SyncCoordinator after daily sync completes.
// Evaluates node_activation_rules against daily_inputs and writes
// pathway_classifications for today's date.
//
// Request body: { userId: string, date: string }   (date: "YYYY-MM-DD")
// Response:     { classified: boolean, pathways: string[] }
//
// Processing pipeline:
//   1. Fetch last 97 days of daily_inputs (90-day baseline window + 7-day eval window)
//   2. Load metric_node_map and node_activation_rules from DB
//   3. For each node: compute within-user deviation, evaluate threshold rule
//   4. Write node_activation_log entries for today
//   5. Per pathway: compute confidence_gate, escalation_level, condition_class, days_in_pattern
//   6. Second pass: cross-pathway compound class assignment
//   7. Upsert pathway_classifications (one row per pathway)
//
// Within-user baseline: median of days [7..97] (90-day window, excluding evaluation window).
// Autonomic deviations are computed as percentage change from baseline.
// Sleep and metabolic deviations are computed as absolute change.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ─────────────────────────────────────────
// TYPES
// ─────────────────────────────────────────

interface ClassifyRequest {
  userId: string;
  date: string;
}

interface DailyInput {
  date: string;
  hrv_ms: number | null;
  resting_hr_bpm: number | null;
  respiratory_rate_rpm: number | null;
  sleep_duration_hrs: number | null;
  sleep_efficiency_pct: number | null;
  steps: number | null;
  active_minutes: number | null;
}

interface NodeMap {
  metric_key: string;
  node_id: string;
  pathway: string;
  weight: number;
}

interface NodeRule {
  node_id: string;
  pathway: string;
  rule_type: string;
  threshold_value: number;
  comparison_operator: string;
  days_window: number;
  required_hits: number;
}

interface NodeResult {
  node_id: string;
  pathway: string;
  fired: boolean;
  weight: number;
  daysInRun: number;
}

interface PathwayResult {
  pathway: string;
  conditionClass: string | null;
  trajectoryLabel: string | null;
  escalationLevel: number;
  confidenceGate: number;
  daysInPattern: number;
}

// ─────────────────────────────────────────
// METRIC → COLUMN NAME MAP
// ─────────────────────────────────────────

const METRIC_COLUMN: Record<string, keyof DailyInput> = {
  hrv_ms:               "hrv_ms",
  resting_hr_bpm:       "resting_hr_bpm",
  respiratory_rate_rpm: "respiratory_rate_rpm",
  sleep_duration_hrs:   "sleep_duration_hrs",
  sleep_efficiency_pct: "sleep_efficiency_pct",
  steps:                "steps",
  active_minutes:       "active_minutes",
};

// Autonomic metrics use percentage deviation from baseline.
// All other metrics use absolute deviation.
const PERCENTAGE_METRICS = new Set(["hrv_ms"]);

// ─────────────────────────────────────────
// MAIN HANDLER
// ─────────────────────────────────────────

serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), { status: 405 });
  }

  let body: ClassifyRequest;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON" }), { status: 400 });
  }

  const { userId, date } = body;
  if (!userId || !date) {
    return new Response(JSON.stringify({ error: "userId and date are required" }), { status: 400 });
  }

  const supabaseUrl  = Deno.env.get("SUPABASE_URL")!;
  const serviceKey   = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const supabase     = createClient(supabaseUrl, serviceKey);

  try {
    // ── 1. Fetch daily_inputs (last 97 days, ascending) ──────────────────────

    const { data: inputs, error: inputErr } = await supabase
      .from("daily_inputs")
      .select("date, hrv_ms, resting_hr_bpm, respiratory_rate_rpm, sleep_duration_hrs, sleep_efficiency_pct, steps, active_minutes")
      .eq("user_id", userId)
      .lte("date", date)
      .order("date", { ascending: true })
      .limit(97);

    if (inputErr) throw inputErr;
    if (!inputs || inputs.length === 0) {
      return json({ classified: false, reason: "no_data" });
    }

    const allDays = inputs as DailyInput[];

    // Split: last 7 days = evaluation window; prior = baseline window
    const evalDays     = allDays.slice(-7);
    const baselineDays = allDays.slice(0, Math.max(allDays.length - 7, 0));

    // ── 2. Load metric_node_map and node_activation_rules ──────────────────

    const [{ data: nodeMapRows }, { data: ruleRows }] = await Promise.all([
      supabase.from("metric_node_map").select("*"),
      supabase.from("node_activation_rules").select("*"),
    ]);

    const nodeMap:   NodeMap[]  = nodeMapRows  as NodeMap[]  ?? [];
    const nodeRules: NodeRule[] = ruleRows     as NodeRule[] ?? [];

    // ── 3. Evaluate each node ────────────────────────────────────────────────

    const nodeResults: NodeResult[] = [];

    for (const rule of nodeRules) {
      const mapping  = nodeMap.find(m => m.node_id === rule.node_id);
      if (!mapping) continue;

      const colKey     = METRIC_COLUMN[mapping.metric_key];
      if (!colKey) continue;

      const usePercent = PERCENTAGE_METRICS.has(mapping.metric_key);

      // Compute baseline value (median of baseline window for this metric)
      const baselineValues = baselineDays
        .map(d => d[colKey] as number | null)
        .filter((v): v is number => v !== null && v > 0);

      if (baselineValues.length < 5) {
        // Not enough history — skip this node
        nodeResults.push({ node_id: rule.node_id, pathway: rule.pathway, fired: false, weight: mapping.weight, daysInRun: 0 });
        continue;
      }

      const baseline = median(baselineValues);

      // Count eval days where deviation meets the threshold rule
      let hitCount = 0;
      const evalWindow = evalDays.slice(-rule.days_window);

      for (const day of evalWindow) {
        const raw = day[colKey] as number | null;
        if (raw === null || raw <= 0) continue;

        const deviation = usePercent
          ? ((raw / baseline) - 1) * 100
          : raw - baseline;

        const meets = compare(deviation, rule.comparison_operator, rule.threshold_value);
        if (meets) hitCount++;
      }

      const fired    = hitCount >= rule.required_hits;
      const daysInRun = fired ? await computeNodeDaysInRun(supabase, userId, rule.node_id, date) : 0;

      nodeResults.push({ node_id: rule.node_id, pathway: rule.pathway, fired, weight: mapping.weight, daysInRun });
    }

    // ── 4. Write node_activation_log ─────────────────────────────────────────

    const logEntries = nodeResults.map(n => ({
      user_id:           userId,
      date:              date,
      node_id:           n.node_id,
      pathway:           n.pathway,
      fired:             n.fired,
      threshold_crossed: n.fired,
      days_in_run:       n.daysInRun,
      schema_version:    "v2.0",
    }));

    if (logEntries.length > 0) {
      await supabase
        .from("node_activation_log")
        .upsert(logEntries, { onConflict: "user_id,date,node_id", ignoreDuplicates: false });
    }

    // ── 5. Compute per-pathway results ───────────────────────────────────────

    const pathways = ["autonomic", "sleep", "metabolic"] as const;
    const pathwayResults: Record<string, PathwayResult> = {};

    for (const pathway of pathways) {
      const pathwayNodes = nodeResults.filter(n => n.pathway === pathway);
      const firedNodes   = pathwayNodes.filter(n => n.fired);

      if (firedNodes.length === 0) {
        pathwayResults[pathway] = {
          pathway,
          conditionClass:  null,
          trajectoryLabel: null,
          escalationLevel: 0,
          confidenceGate:  0.0,
          daysInPattern:   0,
        };
        continue;
      }

      // confidence_gate: weighted proportion of fired nodes
      const totalWeight  = pathwayNodes.reduce((s, n) => s + n.weight, 0);
      const firedWeight  = firedNodes.reduce((s, n) => s + n.weight, 0);
      const confidenceGate = totalWeight > 0 ? Math.min(firedWeight / totalWeight, 1.0) : 0.0;

      const escalationLevel = escalationFromGate(confidenceGate);
      const conditionClass  = singlePathwayClass(pathway);
      const trajectoryLabel = trajectoryLabelFor(conditionClass);
      const daysInPattern   = await computePathwayDaysInPattern(supabase, userId, pathway, date);

      pathwayResults[pathway] = {
        pathway,
        conditionClass,
        trajectoryLabel,
        escalationLevel,
        confidenceGate: Math.round(confidenceGate * 1000) / 1000,
        daysInPattern,
      };
    }

    // ── 6. Cross-pathway compound class assignment ───────────────────────────

    applyCompoundClasses(pathwayResults);

    // ── 7. Upsert pathway_classifications ────────────────────────────────────

    const classificationRows = pathways.map(pathway => {
      const r = pathwayResults[pathway];
      return {
        user_id:            userId,
        date,
        pathway:            r.pathway,
        condition_class:    r.conditionClass,
        trajectory_label:   r.trajectoryLabel,
        escalation_level:   r.escalationLevel,
        confidence_gate:    r.confidenceGate,
        days_in_pattern:    r.daysInPattern,
        schema_version:     "v2.0",
        calibration_status: "active",
        ontology_version:   "v2.0",
      };
    });

    const { error: upsertErr } = await supabase
      .from("pathway_classifications")
      .upsert(classificationRows, { onConflict: "user_id,date,pathway" });

    if (upsertErr) throw upsertErr;

    const classifiedPathways = pathways.filter(p => pathwayResults[p].conditionClass !== null);

    return json({ classified: classifiedPathways.length > 0, pathways: classifiedPathways });

  } catch (err) {
    console.error("[horizon-classify] error:", err);
    return new Response(JSON.stringify({ error: String(err) }), { status: 500 });
  }
});

// ─────────────────────────────────────────
// PURE HELPERS
// ─────────────────────────────────────────

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/** Sorted-middle median. Returns 0 for empty arrays. */
function median(values: number[]): number {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const mid    = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0
    ? (sorted[mid - 1] + sorted[mid]) / 2
    : sorted[mid];
}

function compare(value: number, op: string, threshold: number): boolean {
  switch (op) {
    case "<":  return value < threshold;
    case ">":  return value > threshold;
    case "<=": return value <= threshold;
    case ">=": return value >= threshold;
    default:   return false;
  }
}

function escalationFromGate(gate: number): number {
  if (gate >= 0.75) return 3;
  if (gate >= 0.50) return 2;
  if (gate >= 0.30) return 1;
  return 0;
}

function singlePathwayClass(pathway: string): string {
  switch (pathway) {
    case "autonomic": return "autonomic_stress_load";
    case "sleep":     return "sleep_architecture_disruption";
    case "metabolic": return "metabolic_inactivity_load";
    default:          return "autonomic_stress_load";
  }
}

function trajectoryLabelFor(conditionClass: string | null): string | null {
  if (!conditionClass) return null;
  switch (conditionClass) {
    case "autonomic_stress_load":         return "Autonomic System Under Pressure";
    case "sleep_architecture_disruption": return "Sleep Architecture Under Pressure";
    case "metabolic_inactivity_load":     return "Metabolic Recovery Window";
    case "combined_autonomic_sleep":      return "Recovery Capacity Under Pressure";
    case "combined_metabolic_sleep":      return "Restorative Load Accumulating";
    case "full_system_load":              return "Systemic Resilience Under Pressure";
    default:                              return null;
  }
}

/**
 * Applies cross-pathway compound condition classes (second pass).
 * Mutates pathwayResults in place.
 * Priority: full_system_load > combined > single.
 */
function applyCompoundClasses(results: Record<string, PathwayResult>): void {
  const aActive = results["autonomic"]?.conditionClass !== null;
  const sActive = results["sleep"]?.conditionClass     !== null;
  const mActive = results["metabolic"]?.conditionClass !== null;

  if (aActive && sActive && mActive) {
    results["autonomic"].conditionClass  = "full_system_load";
    results["sleep"].conditionClass      = "full_system_load";
    results["metabolic"].conditionClass  = "full_system_load";
    for (const p of ["autonomic", "sleep", "metabolic"]) {
      results[p].trajectoryLabel = "Systemic Resilience Under Pressure";
    }
    return;
  }

  if (aActive && sActive) {
    results["autonomic"].conditionClass = "combined_autonomic_sleep";
    results["autonomic"].trajectoryLabel = "Recovery Capacity Under Pressure";
    return;
  }

  if (mActive && sActive) {
    results["metabolic"].conditionClass = "combined_metabolic_sleep";
    results["metabolic"].trajectoryLabel = "Restorative Load Accumulating";
    return;
  }
}

// ─────────────────────────────────────────
// ASYNC HELPERS (DB QUERIES)
// ─────────────────────────────────────────

/**
 * Counts consecutive days (ending on `date`) where this node fired.
 * Returns 0 if the node did not fire today.
 */
async function computeNodeDaysInRun(
  // deno-lint-ignore no-explicit-any
  supabase: any,
  userId: string,
  nodeId: string,
  date: string
): Promise<number> {
  const { data } = await supabase
    .from("node_activation_log")
    .select("date, threshold_crossed")
    .eq("user_id", userId)
    .eq("node_id", nodeId)
    .lte("date", date)
    .order("date", { ascending: false })
    .limit(30);

  if (!data || data.length === 0) return 0;

  let count = 0;
  for (const row of data) {
    if (!row.threshold_crossed) break;
    count++;
  }
  return count;
}

/**
 * Counts consecutive days (ending on `date`) where this pathway had an active classification.
 * Uses existing pathway_classifications rows to avoid re-computing history.
 */
async function computePathwayDaysInPattern(
  // deno-lint-ignore no-explicit-any
  supabase: any,
  userId: string,
  pathway: string,
  date: string
): Promise<number> {
  const { data } = await supabase
    .from("pathway_classifications")
    .select("date, confidence_gate")
    .eq("user_id", userId)
    .eq("pathway", pathway)
    .lt("date", date)   // exclude today (not yet written)
    .order("date", { ascending: false })
    .limit(60);

  if (!data) return 1;  // Today is the first day

  let count = 1;  // Start from 1 (today counts)
  let prevDate: Date | null = null;

  for (const row of data) {
    const gate = parseFloat(row.confidence_gate ?? "0");
    if (gate < 0.3) break;  // Pattern ended

    const rowDate = new Date(row.date);
    if (prevDate) {
      const gap = Math.round((prevDate.getTime() - rowDate.getTime()) / 86400000);
      if (gap > 1) break;  // Non-consecutive — pattern interrupted
    }
    count++;
    prevDate = rowDate;
  }

  return count;
}
