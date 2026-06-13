// backend/supabase/functions/_shared/auth.ts
// S13 — Edge Function JWT Verification Utility
//
// Usage in any Edge Function handler:
//
//   const authResult = await verifyCallerOwnsUser(req, userId);
//   if (authResult !== null) return authResult;   // short-circuit on 401/403
//
// This confirms EITHER:
//   1. The caller is a trusted backend service presenting the service key
//      (server-to-server: orchestrator, cron jobs). The end-user is verified
//      once at the edge, so internal hops are trusted without re-validating —
//      this avoids a redundant GoTrue round-trip on every downstream call.
//   OR
//   2. The request carries a valid Supabase user JWT, and that JWT belongs to
//      the user who owns the data being requested (prevents user A from
//      triggering operations on user B's data).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SB_PUBLISHABLE_KEY") ?? Deno.env.get("SUPABASE_ANON_KEY")!;
// Trusted service-to-service credential. New (sb_secret_) takes precedence over
// the legacy reserved key during/after rotation.
const SERVICE_KEY = Deno.env.get("SB_SECRET_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

const corsHeaders = () => ({
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
});

/**
 * True when the request is an internal, trusted server-to-server call presenting
 * the service key (orchestrator, cron jobs). Such callers are already trusted to
 * act on any user, so per-user ownership is not re-checked.
 */
export function isTrustedServiceCaller(req: Request): boolean {
  const token = req.headers.get("Authorization")?.replace("Bearer ", "").trim();
  return !!SERVICE_KEY && !!token && token === SERVICE_KEY;
}

/**
 * Verify the caller's JWT is valid and matches the userId in the request body.
 *
 * @returns null if the caller is authorized (continue processing)
 * @returns a Response object if unauthorized (return this immediately)
 */
export async function verifyCallerOwnsUser(
  req: Request,
  userId: string
): Promise<Response | null> {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return new Response(
      JSON.stringify({ error: "Unauthorized — missing Authorization header" }),
      { status: 401, headers: { "Content-Type": "application/json", ...corsHeaders() } }
    );
  }

  const jwt = authHeader.replace("Bearer ", "").trim();

  // Trusted backend caller (orchestrator, cron) — user already verified at the edge.
  if (SERVICE_KEY && jwt === SERVICE_KEY) return null;

  const client = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  const { data: { user }, error } = await client.auth.getUser(jwt);

  if (error || !user) {
    return new Response(
      JSON.stringify({ error: "Unauthorized — invalid or expired token" }),
      { status: 401, headers: { "Content-Type": "application/json", ...corsHeaders() } }
    );
  }

  if (user.id !== userId) {
    return new Response(
      JSON.stringify({ error: "Forbidden — token does not match requested userId" }),
      { status: 403, headers: { "Content-Type": "application/json", ...corsHeaders() } }
    );
  }

  return null; // authorized
}
