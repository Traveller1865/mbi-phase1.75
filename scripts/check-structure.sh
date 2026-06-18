#!/usr/bin/env bash
# check:structure — guards the canonical backend structure (v1.2 §6.2).
# Flags the duplication/landmine classes that this consolidation removed, so drift
# is caught early. Local guardrail for beta; CI enforcement deferred (Post-Beta).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

fail=0
note() { printf '  %s\n' "$1"; }

# 1) Exactly one config.toml, at backend/supabase — the single deploy root.
cfgs=$(find . -name config.toml \
  -not -path '*/.git/*' -not -path '*/.claude/*' -not -path '*/node_modules/*' \
  2>/dev/null | grep -vE '/\._' || true)
cfg_count=$(printf '%s\n' "$cfgs" | grep -c . || true)
if [ "$cfg_count" -eq 1 ] && printf '%s\n' "$cfgs" | grep -q 'backend/supabase/config.toml'; then
  note "OK: single deploy root (backend/supabase/config.toml)"
else
  note "FAIL: expected exactly one config.toml at backend/supabase; found: ${cfgs:-none}"; fail=1
fi

# 2) No top-level supabase/ (deploy-from-root landmine).
if [ -d supabase ]; then note "FAIL: top-level supabase/ exists (deploy-from-root landmine)"; fail=1; else note "OK: no top-level supabase/"; fi

# 3) No packages/domain (retired duplicate domain logic).
if [ -d packages/domain ]; then note "FAIL: packages/domain exists (duplicate domain logic)"; fail=1; else note "OK: no packages/domain"; fi

# 4) Domain logic lives in exactly one place.
domain_dirs=$(find . -type d -path '*/functions/_shared/domain' \
  -not -path '*/.git/*' -not -path '*/.claude/*' 2>/dev/null | grep -vE '/\._' || true)
dom_count=$(printf '%s\n' "$domain_dirs" | grep -c . || true)
if [ "$dom_count" -eq 1 ]; then note "OK: one canonical domain dir ($domain_dirs)"; else note "FAIL: expected one _shared/domain dir; found: ${domain_dirs:-none}"; fail=1; fi

if [ "$fail" -ne 0 ]; then echo "check:structure FAILED"; exit 1; fi
echo "check:structure passed"
