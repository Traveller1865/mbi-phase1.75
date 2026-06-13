// backend/supabase/functions/horizon/index.ts
// MBI Phase 2 — Horizon Ontology Engine (DEPRECATED)
// DEPRECATED: Superseded by horizon-classify/index.ts (v2.0).
// horizon-classify uses the full metric_node_map + node_activation_rules pipeline
// (writing to pathway_classifications + node_activation_log tables) and is the
// canonical Horizon ontology engine. This file is retained for reference only
// and is NOT registered in config.toml. Do not invoke in new iOS code.
//
// Epic 3 Sprint 1 | Deterministic only. Claude does not run here.
//
// Activation rule set: MBI Knowledge Vault v1.0-derived
//   Autonomic  → autonomic_dysfunction_early  (Sympathetic Dominance node proxy)
//   Sleep      → sleep_fragmentation_early    (Sleep Fragmentation node proxy)
//   Metabolic  → metabolic_risk_inferred      (Glucose Intolerance inferred proxy — no CGM)
//
// Two-condition gate (vault requirement):
//   1. Domain score ≤ 60 for daysInPattern consecutive days
//   2. 7-day domain trend is NOT improving
//
// ConfidenceGate = min(daysInPattern / 14, 1.0)
// EscalationLevel: 0 < 5d | 1 ≥ 5d | 2 ≥ 7d | 3 ≥ 14d + confidenceGate ≥ 0.75 + declining

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { verifyCallerOwnsUser } from "../../functions/_shared/auth.ts";

const SUPABASE_URL      = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SB_SECRET_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const ENGINE_VERSION       = "v1.0-derived";
const CALIBRATION_STATUS   = "pending_biomarker_validation";
const SCORE_THRESHOLD      = 60;
const MIN_DAYS_ACTIVATE    = 5;
const CONFIDENCE_WINDOW    = 14;  // days at which confidenceGate reaches 1.0
const ESCALATION_L3_DAYS   = 14;
const ESCALATION_L3_GATE   = 0.75;

// ─────────────────────────────────────────
// PATHWAY CONFIG
// ─────────────────────────────────────────

type Pathway = "autonomic" | "sleep" | "metabolic";

const PATHWAY_CONFIG: Record<Pathway, {
  scoreKey: "d1_autonomic" | "d2_sleep" | "d3_activity";
  conditionClass: string;
  trajectoryLabel: string;
}> = {
  autonomic: {
    scoreKey:       "d1_autonomic",
    conditionClass: "autonomic_dysfunction_early",
    trajectoryLabel: "Sympathetic load is accumulating",
  },
  sleep: {
    scoreKey:       "d2_sleep",
    conditionClass: "sleep_fragmentation_early",
    trajectoryLabel: "Sleep architecture under pressure",
  },
  metabolic: {
    scoreKey:       "d3_activity",
    conditionClass: "metabolic_risk_inferred",
    trajectoryLabel: "Metabolic stress signal building",
  },
};

// ─────────────────────────────────────────
// DOMAIN TREND — derived from recent scores
// Compares most-recent 3-day avg vs prior 4-day avg within a 7-day window.
// ─────────────────────────────────────────

function computeDomainTrend(
  scores: (number | null)[],  // most-recent first, up to 7 values
): "improving" | "stable" | "declining" {
  const valid = scores.filter((s): s is number => s !== null);
  if (valid.length < 4) return "stable";
  const recent = valid.slice(0, 3);
  const older  = valid.slice(3, 7);
  const recentAvg = recent.reduce((a, b) => a + b, 0) / recent.length;
  const olderAvg  = older.reduce((a, b) => a + b, 0) / older.length;
  const diff = recentAvg - olderAvg;
  if (diff > 3)  return "improving";
  if (diff < -3) return "declining";
  return "stable";
}

// ─────────────────────────────────────────
// DAYS IN PATTERN — consecutive days ≤ threshold (most-recent first)
// ─────────────────────────────────────────

function computeDaysInPattern(
  scores: (number | null)[],
  threshold: number = SCORE_THRESHOLD,
): number {
  let count = 0;
  for (const s of scores) {
    if (s !== null && s <= threshold) {
      count++;
    } else {
      break;
    }
  }
  return count;
}

// ─────────────────────────────────────────
// PATHWAY SIGNAL COMPUTATION
// Returns null for conditionClass/trajectoryLabel when gate not met.
// ─────────────────────────────────────────

interface PathwaySignal {
  pathway: Pathway;
  conditionClass: string | null;
  trajectoryLabel: string | null;
  escalationLevel: number;
  confidenceGate: number;
  daysInPattern: number;
  schemaVersion: string;
  calibrationStatus: string;
}

function computePathwaySignal(
  pathway: Pathway,
  recentScores: (number | null)[],
): PathwaySignal {
  const daysInPattern  = computeDaysInPattern(recentScores);
  const domainTrend    = computeDomainTrend(recentScores);
  const confidenceGate = Math.min(daysInPattern / CONFIDENCE_WINDOW, 1.0);

  const base: PathwaySignal = {
    pathway,
    conditionClass:  null,
    trajectoryLabel: null,
    escalationLevel: 0,
    confidenceGate,
    daysInPattern,
    schemaVersion:      ENGINE_VERSION,
    calibrationStatus:  CALIBRATION_STATUS,
  };

  // Two-condition gate
  if (daysInPattern < MIN_DAYS_ACTIVATE || domainTrend === "improving") {
    return base;
  }

  const { conditionClass, trajectoryLabel } = PATHWAY_CONFIG[pathway];

  let escalationLevel = 1; // daysInPattern ≥ 5, not improving
  if (daysInPattern >= ESCALATION_L3_DAYS && confidenceGate >= ESCALATION_L3_GATE && domainTrend === "declining") {
    escalationLevel = 3;
  } else if (daysInPattern >= 7) {
    escalationLevel = 2;
  }

  return {
    ...base,
    conditionClass,
    trajectoryLabel,
    escalationLevel,
  };
}

// ─────────────────────────────────────────
// HANDLER
// ─────────────────────────────────────────

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders() });
  }

  try {
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);
    const { userId, date } = await req.json();

    if (!userId || !date) {
      return new Response(
        JSON.stringify({ error: "userId and date required" }),
        { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders() } },
      );
    }

    // ── S13: Verify the caller's JWT matches the requested userId ─────
    const authErr = await verifyCallerOwnsUser(req, userId);
    if (authErr !== null) return authErr;

    // ── Fetch last 14 days of domain scores (most recent first) ──────
    const { data: scoreRows, error: scoreErr } = await supabase
      .from("daily_scores")
      .select("date, d1_autonomic, d2_sleep, d3_activity")
      .eq("user_id", userId)
      .order("date", { ascending: false })
      .limit(14);

    if (scoreErr || !scoreRows || scoreRows.length === 0) {
      return new Response(
        JSON.stringify({ error: "No score history — run /score first" }),
        { status: 404, headers: { "Content-Type": "application/json", ...corsHeaders() } },
      );
    }

    // ── Extract per-pathway score series ─────────────────────────────
    const d1Series = scoreRows.map((r) => r.d1_autonomic as number | null);
    const d2Series = scoreRows.map((r) => r.d2_sleep     as number | null);
    const d3Series = scoreRows.map((r) => r.d3_activity  as number | null);

    // ── Compute ontology signals ──────────────────────────────────────
    const signals: PathwaySignal[] = [
      computePathwaySignal("autonomic", d1Series),
      computePathwaySignal("sleep",     d2Series),
      computePathwaySignal("metabolic", d3Series),
    ];

    // ── Upsert to horizon_signals ─────────────────────────────────────
    const rows = signals.map((s) => ({
      user_id:            userId,
      date,
      pathway:            s.pathway,
      condition_class:    s.conditionClass,
      trajectory_label:   s.trajectoryLabel,
      escalation_level:   s.escalationLevel,
      confidence_gate:    s.confidenceGate,
      days_in_pattern:    s.daysInPattern,
      schema_version:     s.schemaVersion,
      calibration_status: s.calibrationStatus,
    }));

    const { error: upsertErr } = await supabase
      .from("horizon_signals")
      .upsert(rows, { onConflict: "user_id,date,pathway" });

    if (upsertErr) throw upsertErr;

    return new Response(
      JSON.stringify({ success: true, signals }),
      { headers: { "Content-Type": "application/json", ...corsHeaders() } },
    );

  } catch (err) {
    console.error("[horizon]", err);
    return new Response(
      JSON.stringify({ error: String(err) }),
      { status: 500, headers: { "Content-Type": "application/json", ...corsHeaders() } },
    );
  }
});

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin":  "*",
    "Access-Control-Allow-Headers": "authorization, content-type",
  };
}
