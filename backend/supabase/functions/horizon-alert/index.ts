// supabase/functions/horizon-alert/index.ts
// OI-018 — Horizon escalation founder alert (beta implementation).
// Called server-to-server from score/index.ts checkHorizonEscalation() ONLY.
// Never called from iOS. Routes to the founder monitoring address only — no user-facing alert.
// verify_jwt = false (config.toml): server-to-server call uses the service key, not a user JWT.
// Requires RESEND_API_KEY environment variable in Supabase project settings.
//
// This function is intentionally separate from escalation-alert (repeat-correction alerts,
// iOS-triggered). Do not merge the two — different trigger, different payload, different purpose.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

interface HorizonAlertPayload {
  userId: string;          // full UUID
  triggeredDate: string;   // ISO date string, e.g. "2026-06-22"
  scoreDay1: number;       // oldest of the three days
  scoreDay2: number;       // middle day
  scoreDay3: number;       // today (the triggering score)
  streakLength: number;    // always 3 for beta (ESCALATION_STREAK constant)
  escalationId?: string;   // horizon_escalations row id if available (may be absent)
}

serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  try {
    const payload: HorizonAlertPayload = await req.json();
    const { userId, triggeredDate, scoreDay1, scoreDay2, scoreDay3, streakLength } = payload;

    // Validation — require core fields. Numbers are checked for null/undefined
    // explicitly (a score of 0 is falsy but valid).
    const missing: string[] = [];
    if (!userId) missing.push("userId");
    if (!triggeredDate) missing.push("triggeredDate");
    if (scoreDay1 == null) missing.push("scoreDay1");
    if (scoreDay2 == null) missing.push("scoreDay2");
    if (scoreDay3 == null) missing.push("scoreDay3");

    if (missing.length > 0) {
      return new Response(
        JSON.stringify({ error: `Missing required field(s): ${missing.join(", ")}` }),
        { status: 400, headers: { "Content-Type": "application/json" } },
      );
    }

    const resendKey = Deno.env.get("RESEND_API_KEY");
    if (!resendKey) {
      console.warn("[horizon-alert] RESEND_API_KEY is not configured — cannot send founder alert email");
      return new Response(
        JSON.stringify({ ok: false, reason: "RESEND_API_KEY not configured" }),
        { status: 500, headers: { "Content-Type": "application/json" } },
      );
    }

    const body = `Horizon escalation detected for beta monitoring.

User: ${userId}
Date: ${triggeredDate}
Score sequence: ${scoreDay1} → ${scoreDay2} → ${scoreDay3}
Streak: ${streakLength} consecutive days below threshold

This is an automated founder alert. No action required unless you choose to follow up.
No outreach has been sent to the user.`;

    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${resendKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: "Chronos Alerts <alerts@myndbodi.com>",
        to: ["hello@myndbodi.com"],
        subject: `[Chronos] Horizon Escalation — ${triggeredDate}`,
        text: body,
      }),
    });

    if (!res.ok) {
      const err = await res.text();
      console.error("[horizon-alert] Resend error:", err);
      // Best-effort: do not throw to the caller; return 500 so score/index.ts can log gracefully.
      return new Response(JSON.stringify({ ok: false, reason: err }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      });
    }

    return new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("[horizon-alert] Unexpected error:", err);
    return new Response(JSON.stringify({ ok: false, reason: String(err) }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
