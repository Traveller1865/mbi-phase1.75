// backend/supabase/functions/narrate-domain-expanded/index.ts
// MBI Phase 1.5 — Domain Expanded Card Narrative Edge Function
// Sprint 3B · Domains Tab
// Called on card expand — not on screen load.
// Receives one domain's score + raw metric values + baseline → returns observational line
// and conflict elaboration if a cross-domain tension exists.
// Prompt Version: 1.1  ← Audit: max_tokens 200 → 250 (prevents truncation on conflict), tone scaffold

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { verifyCallerOwnsUser } from "../../functions/_shared/auth.ts";

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;

const MODEL = "claude-sonnet-4-6";
const PROMPT_VERSION = "1.3";

// ─────────────────────────────────────────
// TYPES
// ─────────────────────────────────────────

interface DomainExpandedInput {
  userId: string;                               // required for auth verification
  domain: string;                               // "D1" through "D5"
  score: number;
  metric_values: Record<string, number | null>; // today's raw values
  baseline_values: Record<string, number | null>;
  conflict_domain: string | null;               // e.g. "D1"
  conflict_type: string | null;                 // e.g. "compensation", "suppression"
}

// ─────────────────────────────────────────
// DOMAIN + METRIC LABELS
// ─────────────────────────────────────────

const DOMAIN_LABELS: Record<string, string> = {
  D1: "autonomic recovery",
  D2: "sleep recovery",
  D3: "activity load",
  D4: "inferred stress",
  D5: "allostatic trend",
};

const METRIC_LABELS: Record<string, string> = {
  hrv_ms:               "HRV",
  resting_hr_bpm:       "resting heart rate",
  sleep_duration_hrs:   "sleep duration",
  sleep_continuity_pct: "sleep continuity",
  steps:                "daily steps",
  active_minutes:       "active minutes",
  d1_baseline:          "autonomic baseline",
  d2_baseline:          "sleep baseline",
  d3_baseline:          "activity baseline",
  d4_baseline:          "stress baseline",
  d5_baseline:          "allostatic baseline",
};

const METRIC_UNITS: Record<string, string> = {
  hrv_ms:               "ms",
  resting_hr_bpm:       "bpm",
  sleep_duration_hrs:   "hrs",
  sleep_continuity_pct: "%",
  steps:                "steps",
  active_minutes:       "min",
};

const CONFLICT_TYPE_LABELS: Record<string, string> = {
  compensation: "compensating for",
  suppression:  "in tension with",
};

// ─────────────────────────────────────────
// RESPONSE TONE SCAFFOLD (Audit §4.2)
// Hardcoded 'balanced' for Phase 1. Phase 2 reads from users table preference.
// ─────────────────────────────────────────

const TONE_INSTRUCTIONS: Record<string, string> = {
  balanced:     "Write in calm, specific, observational framing. This is the default register.",
  clinical:     "Write metric-forward with no metaphor. Short sentences, data-first.",
  motivational: "Write with gentle agency framing. Forward-leaning, but observe-only — no instructions.",
};

// ─────────────────────────────────────────
// FORMAT HELPERS
// ─────────────────────────────────────────

function formatMetricValue(key: string, value: number): string {
  const unit = METRIC_UNITS[key] ?? "";
  if (key === "sleep_duration_hrs") {
    const hrs = Math.floor(value);
    const mins = Math.round((value - hrs) * 60);
    return mins > 0 ? `${hrs}h ${mins}m` : `${hrs}h`;
  }
  if (key === "steps") {
    return `${Math.round(value).toLocaleString()} steps`;
  }
  return `${Math.round(value)}${unit ? " " + unit : ""}`;
}

// ─────────────────────────────────────────
// PROMPT BUILDER
// ─────────────────────────────────────────

function buildPrompt(input: DomainExpandedInput): string {
  const domainLabel = DOMAIN_LABELS[input.domain] ?? input.domain;
  const conflictDomainLabel = input.conflict_domain
    ? DOMAIN_LABELS[input.conflict_domain] ?? input.conflict_domain
    : null;
  const conflictTypeLabel = input.conflict_type
    ? CONFLICT_TYPE_LABELS[input.conflict_type] ?? input.conflict_type
    : null;

  // Format metric values for prompt context
  const metricLines = Object.entries(input.metric_values)
    .filter(([, v]) => v != null)
    .map(([k, v]) => `  ${METRIC_LABELS[k] ?? k}: ${formatMetricValue(k, v as number)}`)
    .join("\n");

  const baselineLines = Object.entries(input.baseline_values)
    .filter(([, v]) => v != null)
    .map(([k, v]) => `  ${METRIC_LABELS[k] ?? k}: ${Math.round(v as number)}`)
    .join("\n");

  const conflictSection = input.conflict_domain
    ? `\nCROSS-DOMAIN TENSION:
This domain is ${conflictTypeLabel} ${conflictDomainLabel}.
Conflict type: ${input.conflict_type}
Name the tension and explain the mechanism briefly in 2–3 sentences. No advice.`
    : "\nNo cross-domain conflict for this domain today.";

  const toneInstruction = TONE_INSTRUCTIONS["balanced"];  // ← Audit §4.2: Phase 2 reads from users table

  return `You are the voice of Mynd & Bodi Institute, a prevention-first health intelligence platform.

Your role is to observe what today's metric values mean for this one domain relative to the user's own baseline. You name what you see. You do not advise.

ABSOLUTE RULES — NEVER VIOLATE:
- Never use clinical language or diagnostic framing
- Never say "autonomic dysfunction", "systemic inflammation", "pathological", or any medical diagnostic term
- Never say "consult a physician" or suggest any action
- This is the expanded card state — it observes only, it never gives behavioral nudges
- Within-user context only — compare today's values only to this user's own baseline
- Tone: calm, specific, informative
- Always use second person — "your HRV", "your baseline", "your body". Never write "this user's", "the user's", or "the body"

DOMAIN: ${domainLabel} (score: ${Math.round(input.score)}/100)

TODAY'S METRIC VALUES:
${metricLines || "  No raw metric values available for this domain"}

USER'S BASELINE:
${baselineLines || "  No baseline available yet"}
${conflictSection}

Generate exactly:

OBSERVATIONAL_LINE: Maximum 1 sentence (50 tokens max). Describe what the body is doing — not what a model computed. Do not reference scores, index values, or scoring logic. Do not use the word "place" as a computational verb (e.g. do not write "place autonomic recovery at..."). Do not begin the sentence with "Today's [metric]" followed by a score number — describe what the body is doing, not what the score is. Write as if explaining a physical state to a curious non-expert. Reference actual metric values (e.g. HRV in ms, sleep in hours) where useful. No advice.
${input.conflict_domain ? "\nCONFLICT_ELABORATION: 2–3 sentences (60 tokens max). Names the tension between the two domains and explains what it means for the body in wellness language. No advice. No instructions." : ""}

RESPONSE TONE (balanced): ${toneInstruction}

Respond in this exact JSON format:
{
  "observational_line": "..."${input.conflict_domain ? ',\n  "conflict_elaboration": "..."' : ""}
}`;
}

// ─────────────────────────────────────────
// HANDLER
// ─────────────────────────────────────────

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders() });
  }

  try {
    const body = await req.json() as DomainExpandedInput;

    const { userId, domain, score, metric_values, baseline_values } = body;

    if (!userId) {
      return new Response(
        JSON.stringify({ error: "userId required" }),
        { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders() } }
      );
    }

    const authErr = await verifyCallerOwnsUser(req, userId);
    if (authErr !== null) return authErr;

    if (!domain || score == null || !metric_values || !baseline_values) {
      return new Response(
        JSON.stringify({ error: "Missing required fields: domain, score, metric_values, baseline_values" }),
        { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders() } }
      );
    }

    const prompt = buildPrompt(body);

    // ── Call Claude API ───────────────────────────────────────────────
    const claudeResponse = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 250,  // ← Audit: bumped from 200 to prevent truncation when conflict_elaboration is present
        system: "You are the Mynd & Bodi Institute wellness voice. Observe only — never advise. Never use clinical language. Respond only with the JSON object requested. No preamble. No markdown.",
        messages: [{ role: "user", content: prompt }],
      }),
    });

    if (!claudeResponse.ok) {
      const err = await claudeResponse.text();
      throw new Error(`Claude API error: ${err}`);
    }

    const claudeData = await claudeResponse.json();
    const rawText = (claudeData.content?.[0]?.text ?? "").trim();

    let parsed: { observational_line: string; conflict_elaboration?: string };
    try {
      const jsonMatch = rawText.match(/\{[\s\S]*\}/);
      parsed = JSON.parse(jsonMatch?.[0] ?? rawText);
    } catch {
      parsed = {
        observational_line: "Today's values are being compared to your personal baseline.",
      };
    }

    const response: Record<string, unknown> = {
      success: true,
      observational_line: parsed.observational_line,
      prompt_version: PROMPT_VERSION,
      model_version: MODEL,
    };

    if (parsed.conflict_elaboration) {
      response.conflict_elaboration = parsed.conflict_elaboration;
    }

    return new Response(
      JSON.stringify(response),
      { headers: { "Content-Type": "application/json", ...corsHeaders() } }
    );

  } catch (err) {
    console.error("[narrate-domain-expanded]", err);
    return new Response(
      JSON.stringify({ error: String(err) }),
      { status: 500, headers: { "Content-Type": "application/json", ...corsHeaders() } }
    );
  }
});

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, content-type",
  };
}