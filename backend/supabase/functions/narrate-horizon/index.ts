// backend/supabase/functions/narrate-horizon/index.ts
// MBI Phase 1.75 — Horizon Trajectory Narrative
// Updated: Ontology Engine v1 integration — reads pathway_classifications
//          instead of receiving synthesized inputs. Spec §8.
//
// Hard constraints (non-negotiable):
//   - No disease names in user-facing copy
//   - No clinical language
//   - No backward-looking language (no 'last week', no score numbers)
//   - Future tense and present-continuous only
//   - condition_class drives routing internally — NEVER surfaced verbatim in copy
//   - CALM state (condition_class null): returns static pathway-specific copy,
//     no Claude call. Each pathway has relationship-aware framing.
//   - If no pathway_classifications rows exist: render Page 1 only (no trajectory language)
//
// Prompt Version: 1.3  ← Spec Amendment v1.0: absolute prohibition list, condition class
//                        to narrative opening line mapping, locked escalation level 3 copy

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { verifyCallerOwnsUser } from "../../functions/_shared/auth.ts";

const SUPABASE_URL         = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SB_SECRET_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const MODEL             = "claude-sonnet-4-6";
const PROMPT_VERSION    = "1.3";
const MAX_TOKENS        = 350;

// ─────────────────────────────────────────
// CONDITION CLASS → NARRATIVE OPENING LINE
// Spec Amendment §3.3 — authoritative mapping. Do not deviate without formal amendment.
// condition_class is internal routing only — these are the permitted user-facing equivalents.
// ─────────────────────────────────────────

const CONDITION_OPENING_LINE: Record<string, string> = {
  autonomic_strain:        "Your recovery system has been under sustained load",
  metabolic_stress_early:  "Your activity and recovery markers have been shifting together — movement has been lower while recovery signals have stayed suppressed",
  sustained_recovery_deficit: "Your recovery has stayed below your usual range",
  recovery_deficit:        "Your recovery markers have been below your usual range",
  load_accumulating:       "Physiological load has been building without a corresponding recovery uplift",
  sleep_debt_compounding:  "Your recent sleep has been shorter than your usual pattern",
  // Legacy values preserved for backward compat during any unprocessed historical rows
  autonomic_dysfunction_early: "Your recovery system has been under elevated load",
  sleep_fragmentation_early:   "Your sleep pattern has been showing sustained disruption",
  metabolic_risk_inferred:     "Your activity and recovery markers have been shifting together",
};

const PATHWAY_LABELS: Record<string, string> = {
  autonomic: "autonomic recovery",
  sleep:     "sleep recovery",
  metabolic: "metabolic balance",
};

// ─────────────────────────────────────────
// CALM STATIC COPY (Audit §2.2 Issue 2)
// When a pathway shows no active signal (conditionClass === null), return
// static relationship-aware copy without a Claude call.
// Each card references its relationship to the other pathways — not just
// its own isolated state. "Keep this going —" prefix removed entirely.
// ─────────────────────────────────────────

const CALM_COPY: Record<string, string> = {
  autonomic: "Balanced autonomic state is your foundation. Days like today are when long-term resilience compounds — the benefit accumulates even when nothing feels dramatic.",
  sleep:     "Your repair window is completing cleanly. This is the input that makes everything else on this page possible — autonomic recovery and metabolic efficiency both depend on it.",
  metabolic: "Consistent movement is protecting your trajectory. The multi-day pattern here matters more than any single number — continuity is the signal.",
};

// ─────────────────────────────────────────
// RESPONSE TONE SCAFFOLD (Audit §4.2)
// Hardcoded 'balanced' for Phase 1. Phase 2 reads from users table preference.
// ─────────────────────────────────────────

const TONE_INSTRUCTIONS: Record<string, string> = {
  balanced:     "Write in warm, observational, body-as-nature framing. Flowing prose, 2–3 sentences. Metaphor permitted. This is the default register.",
  clinical:     "Write metric-forward with no metaphor. Short sentences, data-first, no body-as-nature framing.",
  motivational: "Write with energy and agency framing. Active voice, present tension. Forward-leaning.",
};

// ─────────────────────────────────────────
// PROMPT BUILDER
// ─────────────────────────────────────────

// Spec Amendment §3.1 — absolute prohibition list as system prompt negations
const PROHIBITION_LIST = `ABSOLUTE PROHIBITIONS — THESE TERMS MUST NEVER APPEAR IN YOUR OUTPUT:
- autonomic, autonomic dysfunction, autonomic strain, autonomic condition
- chronic fatigue, fatigue syndrome, CFS, ME/CFS
- metabolic disease, metabolic condition, metabolic risk, early metabolic
- circadian disruption, circadian disorder, circadian dysfunction
- diagnostic, diagnosis, disease, disorder, syndrome
- condition (as a noun describing the user's state)
- risk of [any disease], early signs of [any disease], warning signs of [any disease]
- see a doctor, see a physician, consult a doctor, medical attention, treatment
- condition class, classification category, pattern category
- sleep debt (as a compound noun implying a medical state)
- deficit (as a standalone noun — use 'below your usual range' instead)`;

function buildPrompt(input: {
  pathway: string;
  conditionClass: string;
  trajectoryLabel: string;
  daysInPattern: number;
  escalationLevel: number;
  confidenceGate: number;
  protectivePathway: string | null;
  response_tone: string;
}): string {
  const pathwayLabel    = PATHWAY_LABELS[input.pathway] ?? input.pathway;
  // Spec Amendment §3.3 — use the approved opening line as the observation statement seed
  const openingLine     = CONDITION_OPENING_LINE[input.conditionClass]
    ?? "Your physiological markers have been shifting from your usual range";
  const toneInstruction = TONE_INSTRUCTIONS[input.response_tone] ?? TONE_INSTRUCTIONS["balanced"];

  const counterweight = input.protectivePathway
    ? `PROTECTIVE SIGNAL: The user's ${input.protectivePathway} is currently calm and working against this pattern. Reference this as a counterweight.`
    : "";

  // Spec Amendment §3.2 — pattern context framing
  const patternContext = input.daysInPattern >= 10
    ? `This pattern has persisted for ${input.daysInPattern} days and is now well-established in the signal.`
    : `This pattern has been building for ${input.daysInPattern} days. It is still fully reversible with the right inputs.`;

  // Spec Amendment §3.2 / §5.5 — escalation level 3 language is locked. Do not modify.
  const escalationInstruction = input.escalationLevel >= 3
    ? `ESCALATION LEVEL 3 — USE THIS EXACT CLOSING SENTENCE AND NO OTHER: "This pattern has been present for ${input.daysInPattern} days. It might be useful to share what your data is showing with a healthcare provider who knows you. You can export a summary here."`
    : input.escalationLevel >= 2
    ? "The pattern has been sustained long enough to be worth active attention. Nudge toward one concrete supportive action."
    : "The pattern is still early. Nudge toward one concrete supportive action framed as supportive, not urgent.";

  return `You are the voice of Mynd & Bodi Institute, a prevention-first health intelligence platform.

Your role is to translate a detected physiological pattern into a forward-facing wellness narrative. You are a trusted, knowledgeable guide — not a clinician.

${PROHIBITION_LIST}

REQUIRED FRAMING STRUCTURE (Spec Amendment §3.2):
1. Observation: State what the data shows in personal terms, past tense or present perfect, no causal claim.
   Start with or close to this approved opening: "${openingLine} for the past ${input.daysInPattern} days."
2. Pattern context: Name the pattern without naming a condition. Reference duration and reversibility.
3. Nudge (one only): One concrete action, framed as supportive and not urgent. No alarm language.
${input.escalationLevel >= 3 ? "4. Escalation: Use the locked escalation sentence provided below." : ""}

PATTERN DATA (deterministic — do not alter):
- Body system: ${pathwayLabel}
- Duration: ${input.daysInPattern} days
- Trajectory: ${input.trajectoryLabel}
- ${patternContext}
${counterweight ? `\n${counterweight}` : ""}

${escalationInstruction}

Write 2–3 sentences of connected, forward-facing wellness prose. No alarming language. No clinical language. No lists. No score numbers.

RESPONSE TONE (${input.response_tone}): ${toneInstruction}

Respond with only the narrative text. No labels. No JSON. No preamble.`;
}

// ─────────────────────────────────────────
// HANDLER
// ─────────────────────────────────────────

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders() });
  }

  try {
    const body = await req.json() as {
      userId: string;
      date: string;
      pathway: string;
      // Legacy fields — still accepted for backward compat but DB values take precedence
      conditionClass?: string | null;
      trajectoryLabel?: string | null;
      daysInPattern?: number;
      escalationLevel?: number;
      confidenceGate?: number;
      protectivePathway?: string | null;
    };

    const { userId, date, pathway } = body;

    if (!userId) {
      return new Response(
        JSON.stringify({ error: "userId required" }),
        { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders() } },
      );
    }

    const authErr = await verifyCallerOwnsUser(req, userId);
    if (authErr !== null) return authErr;

    if (!pathway) {
      return new Response(
        JSON.stringify({ error: "pathway required" }),
        { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders() } },
      );
    }

    // ── Query pathway_classifications (Ontology Engine v1) ────────────
    // If no rows exist (ontology-classify skipped or failed), fall back
    // to legacy body params or CALM static copy. Spec §8.
    let conditionClass: string | null   = body.conditionClass ?? null;
    let trajectoryLabel: string | null  = body.trajectoryLabel ?? null;
    let daysInPattern: number           = body.daysInPattern ?? 0;
    let escalationLevel: number         = body.escalationLevel ?? 0;
    let confidenceGate: number          = body.confidenceGate ?? 0;
    const protectivePathway: string | null = body.protectivePathway ?? null;

    if (date) {
      const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);
      const { data: dbRow } = await supabase
        .from("pathway_classifications")
        .select("state,trajectory_label,condition_class,escalation_level,confidence_gate,days_in_pattern")
        .eq("user_id", userId)
        .eq("classification_date", date)
        .eq("pathway_key", pathway)
        .maybeSingle();

      if (dbRow) {
        // DB values take precedence — spec §8: "reads pathway_classifications, not synthesizes"
        conditionClass  = dbRow.condition_class  ?? null;
        trajectoryLabel = dbRow.trajectory_label ?? null;
        daysInPattern   = dbRow.days_in_pattern  ?? 0;
        escalationLevel = dbRow.escalation_level ?? 0;
        confidenceGate  = dbRow.confidence_gate  ?? 0;
        // If DB state is CALM, conditionClass is null — static copy path below
      }
      // If no DB row: use legacy body values (covers fallback when ontology skipped)
    }

    // ── CALM short-circuit ────────────────────────────────────────────
    // conditionClass === null means pathway has no active signal.
    // Return static relationship-aware copy without a Claude call.
    if (!conditionClass) {
      const calmText = CALM_COPY[pathway] ?? "Your body is in a balanced state across this system today.";
      return new Response(
        JSON.stringify({
          success:        true,
          narrative:      calmText,
          calm:           true,
          prompt_version: PROMPT_VERSION,
          model_version:  MODEL,
        }),
        { headers: { "Content-Type": "application/json", ...corsHeaders() } },
      );
    }

    const prompt = buildPrompt({
      pathway, conditionClass, trajectoryLabel: trajectoryLabel ?? "",
      daysInPattern, escalationLevel, confidenceGate,
      protectivePathway: protectivePathway ?? null,
      response_tone: "balanced",  // ← Phase 2 reads from users table
    });

    const claudeResponse = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type":    "application/json",
        "x-api-key":       ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model:      MODEL,
        max_tokens: MAX_TOKENS,
        system: `You are the Mynd & Bodi Institute wellness voice. Write only forward-facing, plain-language wellness narrative. Never use clinical or diagnostic language. Never name diseases or conditions. Never use the words: autonomic, dysfunction, circadian, deficit (alone), disease, disorder, syndrome, diagnosis, chronic fatigue, metabolic risk, sleep debt, condition class. Respond with narrative prose only — no labels, no JSON, no preamble.`,
        messages: [{ role: "user", content: prompt }],
      }),
    });

    if (!claudeResponse.ok) {
      const err = await claudeResponse.text();
      throw new Error(`Claude API error: ${err}`);
    }

    const claudeData = await claudeResponse.json();
    const narrativeText = (claudeData.content?.[0]?.text ?? "").trim();

    if (!narrativeText) throw new Error("Claude returned empty narrative");

    return new Response(
      JSON.stringify({
        success:        true,
        narrative:      narrativeText,
        prompt_version: PROMPT_VERSION,
        model_version:  MODEL,
      }),
      { headers: { "Content-Type": "application/json", ...corsHeaders() } },
    );

  } catch (err) {
    console.error("[narrate-horizon]", err);
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
