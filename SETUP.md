# MBI Phase 1 — Setup Guide
## From Zero to Running on Your iPhone

---

## Prerequisites

| Tool | Install |
|------|---------|
| Xcode 15+ | Mac App Store |
| Node.js 18+ | https://nodejs.org |
| Supabase CLI | `brew install supabase/tap/supabase` |
| Git | Pre-installed on Mac |

---

## Step 1 — Create GitHub Repo

```bash
cd mbi-phase1
git init
git add .
git commit -m "Phase 1 initial scaffold"
gh repo create mbi-phase1 --private
git remote add origin git@github.com:YOUR_USERNAME/mbi-phase1.git
git push -u origin main
```

---

## Step 2 — Supabase Project Setup

1. Go to https://supabase.com → New Project
2. Name it `mbi-phase1`, choose a strong database password
3. Wait for provisioning (~2 min)
4. Go to **Project Settings → API** and copy:
   - **Project URL** (e.g. `https://abcxyz.supabase.co`)
   - **anon/public** key
   - **service_role** key (keep private)

### Push the schema:
```bash
cd backend
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase db push
```

Verify in Supabase Dashboard → Table Editor: you should see all 6 tables.

---

## Step 3 — Set Edge Function Secrets

In Supabase Dashboard → **Edge Functions → Secrets**, add:

| Key | Value |
|-----|-------|
| `ANTHROPIC_API_KEY` | Your Anthropic API key |

---

## Step 4 — Deploy Edge Functions

```bash
cd backend

# Deploy all four functions
supabase functions deploy ingest
supabase functions deploy score
supabase functions deploy narrate
supabase functions deploy admin
```

Test ingest is live:
```bash
curl -X POST "https://YOUR_PROJECT_REF.supabase.co/functions/v1/ingest" \
  -H "Authorization: Bearer YOUR_ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{"payload": {"userId": "test", "date": "2026-04-15", "metrics": {}}}'
```

---

## Step 5 — Domain Package

```bash
cd packages/domain
npm install
npm run test:ts
```

All tests should pass with `✅ All tests passed`.

---

## Step 6 — iOS App Setup

1. Open Xcode → Open `ios/MBI.xcodeproj`
   - If `.xcodeproj` doesn't exist yet, create a new SwiftUI project named `MBI`, then replace the generated files with the ones in `ios/MBI/`

2. Edit `ios/MBI/Config.swift`:
```swift
static let supabaseURL = "https://YOUR_PROJECT_REF.supabase.co"
static let supabaseAnonKey = "YOUR_ANON_KEY"
```

3. Add HealthKit capability:
   - Select MBI target → **Signing & Capabilities** → `+` → **HealthKit**

4. Add `Info.plist` keys:
```xml
<key>NSHealthShareUsageDescription</key>
<string>Mynd & Bodi reads your Apple Watch health data to calculate your daily Chronos Resilience Score.</string>
```

5. Set your Apple Developer Team under **Signing**

6. Connect your iPhone via USB → Select your device → **Run (⌘R)**

---

## Step 7 — Create Your Admin Account

1. Launch the app → Create Account with your email
2. In Supabase Dashboard → Table Editor → `user_roles`, insert:
```sql
INSERT INTO user_roles (user_id, role) VALUES ('YOUR_USER_UUID', 'admin');
```
Find your UUID in the `users` table.

---

## Step 8 — Founder Validation Run (Sprint 8)

- Use the app as your sole daily health interface for 7 days
- Fill in the Sprint Tracker daily log
- Make no code changes during the window
- Evaluate all 5 exit criteria at Day 7

---

## Troubleshooting

**HealthKit returns nil for all metrics:**
Settings → Privacy & Security → Health → MBI → enable all toggles

**Edge function 500 errors:**
Supabase Dashboard → Edge Functions → Logs → check error detail

**Score not generating:**
Ensure `daily_inputs` row exists for the date before calling `/score`

**Claude API errors in /narrate:**
Verify `ANTHROPIC_API_KEY` is set in Supabase Edge Function secrets

---

## Environment Variables Summary

| Location | Variable | Value |
|----------|----------|-------|
| iOS Config.swift | `supabaseURL` | Your Supabase project URL |
| iOS Config.swift | `supabaseAnonKey` | Your anon key |
| Supabase Secrets | `ANTHROPIC_API_KEY` | Your Anthropic key |
| Supabase Secrets | `SUPABASE_SERVICE_ROLE_KEY` | Auto-injected by Supabase |
