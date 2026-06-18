// backend/supabase/functions/_tests_integration/smoke.test.ts
// MBI — Integration / smoke tests against the DEPLOYED Edge Functions.
// Catches the class unit tests can't: Deno import resolution, routing, env wiring,
// Supabase client behavior, deployed regressions.
//
// REQUIRES env (no secrets in this file): PROJECT_URL (or SUPABASE_URL) + SB_SECRET_KEY.
// If unset, every test is `ignore`d (skips, does not fail) — safe to run without creds.
//
// SIDE EFFECTS (see ../_shared/domain/__tests__/README.md and the CP-4 report):
//   - ping              : none (health probe).
//   - score             : idempotent UPSERT of daily_scores (+ shadow/trend rows) for the
//                          primary test user on an EXISTING date — deterministic overwrite.
//   - ontology-classify : idempotent UPSERT of node_activations / pathway_classifications
//                          for the same user/date — deterministic overwrite.
//   narrate is intentionally NOT exercised here (it calls the Claude API — cost + writes).
//   Only the primary test user + an existing date are touched; no new users, no new dates.

const PROJECT_URL = Deno.env.get("PROJECT_URL") ?? Deno.env.get("SUPABASE_URL");
const SB_SECRET_KEY = Deno.env.get("SB_SECRET_KEY");
const USER = "c1992eec-7328-4dc1-8fea-55e2b3b07d3e";
const DATE = "2026-06-12";

const ready = (): boolean => !!PROJECT_URL && !!SB_SECRET_KEY;

async function call(path: string, body: unknown): Promise<{ status: number; json: Record<string, unknown> }> {
  const res = await fetch(`${PROJECT_URL}/functions/v1/${path}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${SB_SECRET_KEY}`,
      "apikey": SB_SECRET_KEY ?? "",
    },
    body: JSON.stringify(body),
  });
  const json = await res.json().catch(() => ({}));
  return { status: res.status, json };
}

Deno.test({
  name: "smoke: ping is healthy (no side effects)",
  ignore: !ready(),
  fn: async () => {
    const r = await call("ping", {});
    if (r.status !== 200) throw new Error(`ping returned ${r.status}`);
  },
});

Deno.test({
  name: "smoke: score returns 200 for the primary user (idempotent upsert)",
  ignore: !ready(),
  fn: async () => {
    const r = await call("score", { userId: USER, date: DATE });
    if (r.status !== 200) throw new Error(`score returned ${r.status}: ${JSON.stringify(r.json)}`);
    if (!("score" in r.json) && !("result" in r.json)) {
      throw new Error("score response missing score/result payload");
    }
  },
});

Deno.test({
  name: "smoke: ontology-classify returns 200 for the primary user (idempotent upsert)",
  ignore: !ready(),
  fn: async () => {
    const r = await call("ontology-classify", { user_id: USER, date: DATE });
    if (r.status !== 200) throw new Error(`ontology-classify returned ${r.status}: ${JSON.stringify(r.json)}`);
  },
});
