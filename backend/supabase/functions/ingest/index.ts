// backend/supabase/functions/ingest/index.ts
// MBI Phase 1 — Ingestion & Canonicalization Layer
// Version: 1.2 | H-01: Tier 1 metric expansion | Data Tier Architecture

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { verifyCallerOwnsUser } from "../../functions/_shared/auth.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SB_SECRET_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SOURCE_VERSION = "1.2";

// ── Section 2: Data Tier ─────────────────────────────────────────────────────
// Wearable-specific signals: require Apple Watch (or compatible wearable).
// steps is intentionally excluded from the wearable array — iPhone-only capable.
type DataTier = "wearable" | "partial" | "steps_only" | "unknown";

const WEARABLE_SIGNALS = [
  "hrv_ms",
  "resting_hr_bpm",
  "sleep_duration_hrs",
  "respiratory_rate_rpm",
  "sleep_continuity_pct",
  "spo2_pct",
  "stand_hours",
  "active_minutes",
] as const;

function classifyDataTier(clean: Record<string, number | null>): DataTier {
  const wearableCount = WEARABLE_SIGNALS.filter((s) => clean[s] != null).length;
  if (wearableCount >= 4) return "wearable";
  if (wearableCount >= 1) return "partial";
  // Zero wearable signals — check if at least steps/activity data is present
  const hasActivityData =
    clean.steps != null || clean.active_minutes != null || clean.distance_km != null;
  return hasActivityData ? "steps_only" : "unknown";
}

interface RawHealthKitPayload {
  userId: string;
  date: string;
  metrics: {
    hrv_ms?: number | null;
    resting_hr_bpm?: number | null;
    respiratory_rate_rpm?: number | null;
    sleep_duration_hrs?: number | null;
    sleep_continuity_pct?: number | null;
    steps?: number | null;
    active_minutes?: number | null;
    distance_km?: number | null;
    // H-01: Tier 1 expansion
    spo2_pct?: number | null;
    resting_energy?: number | null;
    stand_hours?: number | null;
    // Third-party device supplementary metrics (Fix 6d)
    // blood_pressure_*: from iHealth devices via HealthKit
    // weight_lbs / body_fat_pct: from VeSync scales via HealthKit
    // These are null for Apple Watch-only users and are NOT wearable discriminators.
    blood_pressure_systolic?: number | null;
    blood_pressure_diastolic?: number | null;
    weight_lbs?: number | null;
    body_fat_pct?: number | null;
  };
}

interface DataQualityFlags {
  missing_metrics: string[];
  out_of_range: Record<string, string>;
  is_complete: boolean;
}

function canonicalize(raw: RawHealthKitPayload): {
  row: Record<string, unknown>;
  flags: DataQualityFlags;
  data_tier: DataTier;
} {
  const flags: DataQualityFlags = { missing_metrics: [], out_of_range: {}, is_complete: false };
  const clean: Record<string, number | null> = {};

  // ── Existing metrics ──────────────────────────────────────────
  if (raw.metrics.hrv_ms == null) { flags.missing_metrics.push("hrv_ms"); clean.hrv_ms = null; }
  else if (raw.metrics.hrv_ms < 0 || raw.metrics.hrv_ms > 300) { flags.out_of_range["hrv_ms"] = `${raw.metrics.hrv_ms} out of [0,300]`; clean.hrv_ms = null; }
  else { clean.hrv_ms = Math.round(raw.metrics.hrv_ms * 10) / 10; }

  if (raw.metrics.resting_hr_bpm == null) { flags.missing_metrics.push("resting_hr_bpm"); clean.resting_hr_bpm = null; }
  else if (raw.metrics.resting_hr_bpm < 30 || raw.metrics.resting_hr_bpm > 200) { flags.out_of_range["resting_hr_bpm"] = `${raw.metrics.resting_hr_bpm} out of [30,200]`; clean.resting_hr_bpm = null; }
  else { clean.resting_hr_bpm = Math.round(raw.metrics.resting_hr_bpm * 10) / 10; }

  if (raw.metrics.respiratory_rate_rpm == null) { flags.missing_metrics.push("respiratory_rate_rpm"); clean.respiratory_rate_rpm = null; }
  else if (raw.metrics.respiratory_rate_rpm < 6 || raw.metrics.respiratory_rate_rpm > 40) { flags.out_of_range["respiratory_rate_rpm"] = `${raw.metrics.respiratory_rate_rpm} out of [6,40]`; clean.respiratory_rate_rpm = null; }
  else { clean.respiratory_rate_rpm = Math.round(raw.metrics.respiratory_rate_rpm * 10) / 10; }

  if (raw.metrics.sleep_duration_hrs == null) { flags.missing_metrics.push("sleep_duration_hrs"); clean.sleep_duration_hrs = null; }
  else if (raw.metrics.sleep_duration_hrs < 0 || raw.metrics.sleep_duration_hrs > 16) { flags.out_of_range["sleep_duration_hrs"] = `${raw.metrics.sleep_duration_hrs} out of [0,16]`; clean.sleep_duration_hrs = null; }
  else { clean.sleep_duration_hrs = Math.round(raw.metrics.sleep_duration_hrs * 100) / 100; }

  if (raw.metrics.sleep_continuity_pct == null) { flags.missing_metrics.push("sleep_continuity_pct"); clean.sleep_continuity_pct = null; }
  else if (raw.metrics.sleep_continuity_pct < 0 || raw.metrics.sleep_continuity_pct > 100) { flags.out_of_range["sleep_continuity_pct"] = `${raw.metrics.sleep_continuity_pct} out of [0,100]`; clean.sleep_continuity_pct = null; }
  else { clean.sleep_continuity_pct = Math.round(raw.metrics.sleep_continuity_pct * 10) / 10; }

  if (raw.metrics.steps == null) { flags.missing_metrics.push("steps"); clean.steps = null; }
  else { clean.steps = Math.max(0, Math.round(raw.metrics.steps)); }

  if (raw.metrics.active_minutes == null) { flags.missing_metrics.push("active_minutes"); clean.active_minutes = null; }
  else { clean.active_minutes = Math.max(0, Math.round(raw.metrics.active_minutes)); }

  clean.distance_km = raw.metrics.distance_km != null
    ? Math.round(raw.metrics.distance_km * 100) / 100
    : null;

  // ── H-01: Tier 1 metrics — optional, never block is_complete ──
  // spo2_pct: valid range 70–100%
  if (raw.metrics.spo2_pct == null) {
    clean.spo2_pct = null;
  } else if (raw.metrics.spo2_pct < 70 || raw.metrics.spo2_pct > 100) {
    flags.out_of_range["spo2_pct"] = `${raw.metrics.spo2_pct} out of [70,100]`;
    clean.spo2_pct = null;
  } else {
    clean.spo2_pct = Math.round(raw.metrics.spo2_pct * 10) / 10;
  }

  // resting_energy: kcal/day, valid range 500–5000
  if (raw.metrics.resting_energy == null) {
    clean.resting_energy = null;
  } else if (raw.metrics.resting_energy < 500 || raw.metrics.resting_energy > 5000) {
    flags.out_of_range["resting_energy"] = `${raw.metrics.resting_energy} out of [500,5000]`;
    clean.resting_energy = null;
  } else {
    clean.resting_energy = Math.round(raw.metrics.resting_energy);
  }

  // stand_hours: valid range 0–24
  if (raw.metrics.stand_hours == null) {
    clean.stand_hours = null;
  } else if (raw.metrics.stand_hours < 0 || raw.metrics.stand_hours > 24) {
    flags.out_of_range["stand_hours"] = `${raw.metrics.stand_hours} out of [0,24]`;
    clean.stand_hours = null;
  } else {
    clean.stand_hours = Math.round(raw.metrics.stand_hours * 10) / 10;
  }

  // Fix 6d: Third-party supplementary metrics — iHealth (blood pressure) and VeSync (weight)
  // These are NOT wearable discriminators and are NOT included in WEARABLE_SIGNALS.
  // blood_pressure_systolic: mmHg, valid range 60–250
  if (raw.metrics.blood_pressure_systolic == null) {
    clean.blood_pressure_systolic = null;
  } else if (raw.metrics.blood_pressure_systolic < 60 || raw.metrics.blood_pressure_systolic > 250) {
    flags.out_of_range["blood_pressure_systolic"] = `${raw.metrics.blood_pressure_systolic} out of [60,250]`;
    clean.blood_pressure_systolic = null;
  } else {
    clean.blood_pressure_systolic = Math.round(raw.metrics.blood_pressure_systolic);
  }

  // blood_pressure_diastolic: mmHg, valid range 40–150
  if (raw.metrics.blood_pressure_diastolic == null) {
    clean.blood_pressure_diastolic = null;
  } else if (raw.metrics.blood_pressure_diastolic < 40 || raw.metrics.blood_pressure_diastolic > 150) {
    flags.out_of_range["blood_pressure_diastolic"] = `${raw.metrics.blood_pressure_diastolic} out of [40,150]`;
    clean.blood_pressure_diastolic = null;
  } else {
    clean.blood_pressure_diastolic = Math.round(raw.metrics.blood_pressure_diastolic);
  }

  // weight_lbs: valid range 50–700 lbs
  if (raw.metrics.weight_lbs == null) {
    clean.weight_lbs = null;
  } else if (raw.metrics.weight_lbs < 50 || raw.metrics.weight_lbs > 700) {
    flags.out_of_range["weight_lbs"] = `${raw.metrics.weight_lbs} out of [50,700]`;
    clean.weight_lbs = null;
  } else {
    clean.weight_lbs = Math.round(raw.metrics.weight_lbs * 10) / 10;
  }

  // body_fat_pct: valid range 1–60%
  if (raw.metrics.body_fat_pct == null) {
    clean.body_fat_pct = null;
  } else if (raw.metrics.body_fat_pct < 1 || raw.metrics.body_fat_pct > 60) {
    flags.out_of_range["body_fat_pct"] = `${raw.metrics.body_fat_pct} out of [1,60]`;
    clean.body_fat_pct = null;
  } else {
    clean.body_fat_pct = Math.round(raw.metrics.body_fat_pct * 10) / 10;
  }

  // is_complete only tracks original 7 primary metrics — Tier 1 are bonus
  const primaryMetrics = [
    "hrv_ms", "resting_hr_bpm", "respiratory_rate_rpm",
    "sleep_duration_hrs", "sleep_continuity_pct", "steps", "active_minutes",
  ];
  flags.is_complete = primaryMetrics.every((m) => clean[m] != null);

  // ── Section 3: Classify data tier and include in upsert row ─────────────────
  const data_tier = classifyDataTier(clean);

  return {
    row: {
      user_id: raw.userId,
      date: raw.date,
      ...clean,
      data_quality_flags: flags,
      source_version: SOURCE_VERSION,
      // Section 3: tier + gap_reason written at ingest time
      data_tier,
      gap_reason: null,  // null until user validates via gap prompt (Section 7)
    },
    flags,
    data_tier,
  };
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "authorization, content-type",
      },
    });
  }

  try {
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);
    const body = await req.json();
    const payloads: RawHealthKitPayload[] = Array.isArray(body.payload)
      ? body.payload
      : [body.payload];

    // ── S13: Verify the caller's JWT matches the userId in the payload ─
    // All payloads in a single request must belong to the same user.
    const callerUserId = payloads[0]?.userId;
    if (!callerUserId) {
      return new Response(
        JSON.stringify({ error: "userId required in payload" }),
        { status: 400, headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" } }
      );
    }
    const authErr = await verifyCallerOwnsUser(req, callerUserId);
    if (authErr !== null) return authErr;

    const results = [];

    for (const payload of payloads) {
      const { row, flags, data_tier } = canonicalize(payload);

      // Section 2: Log steps_only days — these are skipped by the scoring engine.
      if (data_tier === "steps_only") {
        console.log(
          `[ingest] steps_only day for user ${payload.userId} on ${payload.date} — ` +
          `no wearable signals detected. Scoring will be skipped.`
        );
      }

      const { data, error } = await supabase
        .from("daily_inputs")
        .upsert(row, { onConflict: "user_id,date" })
        .select()
        .single();

      if (error) {
        return new Response(
          JSON.stringify({ error: error.message, code: error.code, details: error.details, hint: error.hint }),
          { status: 400, headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" } }
        );
      }
      results.push({ date: payload.date, id: data.id, data_tier, flags });
    }

    return new Response(
      JSON.stringify({ success: true, ingested: results }),
      { headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" } }
    );
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return new Response(
      JSON.stringify({ error: message }),
      { status: 500, headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" } }
    );
  }
});