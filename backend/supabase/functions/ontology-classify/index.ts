// backend/supabase/functions/ontology-classify/index.ts
// MBI Ontology Engine v1 — Deterministic Node Activation + Pathway Classification
// Spec: MBI_Chronos_BuildHandoff_OntologyEngineV1_v1_0.docx
// Ontology version: phase1_75-v1.0
//
// ARCHITECTURAL INVARIANT:
//   Downstream of scoring, upstream of narrative.
//   Does NOT modify daily_scores, baselines, or any scoring table.
//   Does NOT call the Claude API. All logic is deterministic threshold comparison.
//   Failure here must never crash the score-orchestrator.
//
// Execution flow:
//   1. Fetch: daily_inputs (30d), baselines, daily_scores (30d),
//             node_activations (30d), pathway_classifications (30d)
//   2. Trust state gate — skip if calibrating
//   3. Evaluate 12 activation rules → upsert node_activations (12 rows)
//   4. Classify 3 pathways → upsert pathway_classifications (3 rows)
//   5. Return { classified: true, pathways: [...] }

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { evaluateAllNodes } from "../../functions/_shared/domain/ontology/activate.ts";
import { classifyPathway }  from "../../functions/_shared/domain/ontology/pathway.ts";
import { ONTOLOGY_VERSION } from "../../functions/_shared/domain/ontology/types.ts";
import type {
  EvaluationContext,
  TrustState,
  PathwayKey,
} from "../../functions/_shared/domain/ontology/types.ts";

const SUPABASE_URL         = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SB_SECRET_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const PATHWAYS: PathwayKey[] = ["autonomic", "sleep", "metabolic"];

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders() });
  }

  try {
    const { user_id, date } = await req.json() as { user_id: string; date: string };

    if (!user_id || !date) {
      return new Response(JSON.stringify({ error: "user_id and date required" }), {
        status: 400, headers: { "Content-Type": "application/json", ...corsHeaders() },
      });
    }

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);

    // ── STEP 1: Fetch all input data ──────────────────────────────────

    const [
      { data: inputs30d },
      { data: baselinesRow },
      { data: scores30d },
      { data: priorActivations },
      { data: priorPathways },
      { data: userRow },
    ] = await Promise.all([
      supabase
        .from("daily_inputs")
        .select("date,hrv_ms,resting_hr_bpm,respiratory_rate_rpm,sleep_duration_hrs,sleep_continuity_pct,steps,active_minutes")
        .eq("user_id", user_id)
        .lt("date", date)
        .order("date", { ascending: true })
        .limit(30),
      supabase
        .from("baselines")
        .select("*")
        .eq("user_id", user_id)
        .lte("computed_on", date)
        .order("computed_on", { ascending: false })
        .limit(1)
        .maybeSingle(),
      supabase
        .from("daily_scores")
        .select("date,d1_autonomic,d2_sleep,d3_activity,chronos_score")
        .eq("user_id", user_id)
        .lt("date", date)
        .order("date", { ascending: true })
        .limit(30),
      supabase
        .from("node_activations")
        .select("node_id,activation_date,is_active,days_active,ontology_nodes(node_key)")
        .eq("user_id", user_id)
        .lt("activation_date", date)
        .order("activation_date", { ascending: true })
        .limit(30 * 12),
      supabase
        .from("pathway_classifications")
        .select("pathway_key,state,classification_date")
        .eq("user_id", user_id)
        .lt("classification_date", date)
        .order("classification_date", { ascending: false })
        .limit(90),
      supabase
        .from("users")
        .select("timezone_shift_detected,timezone_shift_date")
        .eq("id", user_id)
        .maybeSingle(),
    ]);

    // ── Guard: no baselines row ───────────────────────────────────────
    if (!baselinesRow) {
      console.log(`[ontology-classify] No baselines for user ${user_id} on ${date} — skipping`);
      return new Response(JSON.stringify({ skipped: true, reason: "no_baselines" }), {
        headers: { "Content-Type": "application/json", ...corsHeaders() },
      });
    }

    // ── Guard: no daily_inputs ────────────────────────────────────────
    if (!inputs30d || inputs30d.length === 0) {
      console.log(`[ontology-classify] No daily_inputs for user ${user_id} — skipping`);
      return new Response(JSON.stringify({ skipped: true, reason: "no_inputs" }), {
        headers: { "Content-Type": "application/json", ...corsHeaders() },
      });
    }

    // ── STEP 2: Trust state gate ──────────────────────────────────────
    const trustState = (baselinesRow.range_trust_state ?? "establishing") as TrustState;
    if (trustState === "calibrating" || trustState === "establishing") {
      console.log(`[ontology-classify] Trust state ${trustState} — skipping`);
      return new Response(JSON.stringify({ skipped: true, reason: `trust_state_${trustState}` }), {
        headers: { "Content-Type": "application/json", ...corsHeaders() },
      });
    }

    // ── Normalise prior activations (join with node_key) ─────────────
    // deno-lint-ignore no-explicit-any
    const priorActivationRows = (priorActivations ?? []).map((row: any) => ({
      node_key:        row.ontology_nodes?.node_key ?? "",
      activation_date: row.activation_date,
      is_active:       row.is_active,
      days_active:     row.days_active,
    })).filter(r => r.node_key !== "");

    // ── Build evaluation context ──────────────────────────────────────
    const ctx: EvaluationContext = {
      date,
      isWeekend: (() => { const d = new Date(date).getUTCDay(); return d === 0 || d === 6; })(),
      inputs30d:           inputs30d ?? [],
      scores30d:           scores30d ?? [],
      baselines:           baselinesRow,
      priorActivations30d: priorActivationRows,
      priorPathways30d:    (priorPathways ?? []).map((r: { pathway_key: string; state: string; classification_date: string }) => ({
        pathway_key:         r.pathway_key,
        state:               r.state,
        classification_date: r.classification_date,
      })),
      trustState,
    };

    // ── Fetch node_id → node_key mapping ─────────────────────────────
    const { data: nodeRows } = await supabase
      .from("ontology_nodes")
      .select("id, node_key")
      .eq("is_active", true);

    const nodeKeyToId = new Map<string, string>(
      (nodeRows ?? []).map((n: { id: string; node_key: string }) => [n.node_key, n.id]),
    );

    // ── STEP 3: Evaluate all 12 activation rules ──────────────────────
    const activations = evaluateAllNodes(ctx);

    // ── Travel suppression (Change 3) ─────────────────────────────────
    // If timezone_shift_detected within 4 days: suppress circadian_disruption
    // and sleep_fragmentation. After 5 days: clear the flags.
    if (userRow?.timezone_shift_detected && userRow?.timezone_shift_date) {
      const todayMs     = new Date(date).getTime();
      const shiftMs     = new Date(userRow.timezone_shift_date as string).getTime();
      const daysSinceShift = Math.round((todayMs - shiftMs) / 86_400_000);

      if (daysSinceShift <= 4) {
        const suppressed = { is_active: false, activation_strength: 0, contributing_metrics: [], days_active: 0, skipped_reason: "travel_suppression" };
        activations.set("circadian_disruption", { node_key: "circadian_disruption",  ...suppressed });
        activations.set("sleep_fragmentation",  { node_key: "sleep_fragmentation",   ...suppressed });
      } else {
        // Suppression window expired — clear the flags
        await supabase.from("users")
          .update({ timezone_shift_detected: false, timezone_shift_date: null })
          .eq("id", user_id);
      }
    }

    // ── STEP 4: Upsert node_activations ──────────────────────────────
    const activationUpserts = Array.from(activations.values()).map(r => {
      const node_id = nodeKeyToId.get(r.node_key);
      if (!node_id) return null;
      return {
        user_id,
        node_id,
        activation_date:      date,
        is_active:            r.is_active,
        activation_strength:  r.activation_strength,
        contributing_metrics: r.contributing_metrics,
        days_active:          r.days_active,
        ontology_version:     ONTOLOGY_VERSION,
        skipped_reason:       r.skipped_reason ?? null,
      };
    }).filter(Boolean);

    const { error: activErr } = await supabase
      .from("node_activations")
      .upsert(activationUpserts, { onConflict: "user_id,node_id,activation_date" });

    if (activErr) {
      console.error("[ontology-classify] node_activations upsert error:", activErr);
      // Non-fatal — continue to pathway classification
    }

    // ── STEP 5: Classify 3 pathways ───────────────────────────────────
    const pathwayResults = PATHWAYS.map(pathway => classifyPathway(pathway, activations, ctx));

    // ── STEP 6: Upsert pathway_classifications ────────────────────────
    const pathwayUpserts = pathwayResults.map(p => ({
      user_id,
      classification_date: date,
      pathway_key:         p.pathway_key,
      state:               p.state,
      trajectory_label:    p.trajectory_label,
      condition_class:     p.condition_class,
      escalation_level:    p.escalation_level,
      confidence_gate:     p.confidence_gate,
      days_in_pattern:     p.days_in_pattern,
      activating_nodes:    p.activating_nodes,
      ontology_version:    ONTOLOGY_VERSION,
    }));

    const { error: pathwayErr } = await supabase
      .from("pathway_classifications")
      .upsert(pathwayUpserts, { onConflict: "user_id,classification_date,pathway_key" });

    if (pathwayErr) {
      console.error("[ontology-classify] pathway_classifications upsert error:", pathwayErr);
    }

    // ── STEP 7: Suppressed classification logging (Change 5) ──────────
    // For non-CALM pathways where confidence_gate < 0.50, write an additional
    // audit row to suppressed_classifications. The pathway_classifications row
    // is always written regardless — this is additive only.
    const suppressedUpserts = pathwayResults
      .filter(p => p.state !== "CALM" && p.confidence_gate < 0.50)
      .map(p => ({
        user_id,
        classification_date: date,
        pathway_key:         p.pathway_key,
        state:               p.state,
        confidence_gate:     p.confidence_gate,
        trust_factor:        p._trustFactor,
        depth_factor:        p._depthFactor,
        stability_factor:    p._stabilityFactor,
        activating_nodes:    p.activating_nodes,
        condition_class:     p.condition_class,
        ontology_version:    ONTOLOGY_VERSION,
      }));

    if (suppressedUpserts.length > 0) {
      const { error: suppressErr } = await supabase
        .from("suppressed_classifications")
        .upsert(suppressedUpserts, { onConflict: "user_id,classification_date,pathway_key" });
      if (suppressErr) {
        console.error("[ontology-classify] suppressed_classifications upsert error:", suppressErr);
      }
    }

    // ── STEP 8: Return ────────────────────────────────────────────────
    return new Response(
      JSON.stringify({
        classified: true,
        pathways: pathwayResults.map(p => ({
          pathway_key:      p.pathway_key,
          state:            p.state,
          escalation_level: p.escalation_level,
          confidence_gate:  p.confidence_gate,
        })),
      }),
      { headers: { "Content-Type": "application/json", ...corsHeaders() } },
    );

  } catch (err) {
    console.error("[ontology-classify] error:", err);
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500, headers: { "Content-Type": "application/json", ...corsHeaders() },
    });
  }
});

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin":  "*",
    "Access-Control-Allow-Headers": "authorization, content-type",
  };
}
