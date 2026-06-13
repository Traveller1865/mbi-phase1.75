// supabase/functions/escalation-alert/index.ts
// Step 8 Part F — Repeat correction escalation email.
// Called fire-and-forget from the iOS client after is_applied correction count >= 3 in 14 days.
// Requires RESEND_API_KEY environment variable in Supabase project settings.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { verifyCallerOwnsUser } from "../../functions/_shared/auth.ts";

interface Correction {
  date: string;
  original_value: number | null;
  corrected_value: number;
}

interface EscalationPayload {
  userId: string;
  signalName: string;
  corrections: Correction[];
}

serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  try {
    const payload: EscalationPayload = await req.json();
    const { userId, signalName, corrections } = payload;

    if (!userId) {
      return new Response(JSON.stringify({ error: "userId required" }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      });
    }

    const authErr = await verifyCallerOwnsUser(req, userId);
    if (authErr !== null) return authErr;

    const resendKey = Deno.env.get("RESEND_API_KEY");
    if (!resendKey) {
      // Escalation alerts are security-critical — a missing API key is an ops error, not a soft failure.
      throw new Error("[escalation-alert] RESEND_API_KEY is not configured — cannot send security alert email");
    }

    const correctionLines = corrections
      .slice(0, 3)
      .map(
        (c) =>
          `  ${c.date} | original: ${c.original_value ?? "null"} | corrected: ${c.corrected_value}`
      )
      .join("\n");

    const body = `User ID: ${userId}
Signal: ${signalName}
Correction count (14 days): ${corrections.length}

Last ${Math.min(corrections.length, 3)} corrections:
${correctionLines}`;

    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${resendKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: "Chronos Alerts <alerts@myndbodi.com>",
        to: ["hello@myndbodi.com"],
        subject: `Repeated correction flag — ${signalName} / ${userId}`,
        text: body,
      }),
    });

    if (!res.ok) {
      const err = await res.text();
      console.error("[escalation-alert] Resend error:", err);
      return new Response(JSON.stringify({ ok: false, reason: err }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    return new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("[escalation-alert] Unexpected error:", err);
    return new Response(JSON.stringify({ ok: false, reason: String(err) }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
