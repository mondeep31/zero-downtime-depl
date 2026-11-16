#!/usr/bin/env bash
# Statelessness check: the rate limit is 20 per minute per client. With the
# counter in Redis, 40 requests spread over 2 replicas must give exactly
# 20 x 200 and 20 x 429. A per-process counter would let 40 through.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

reset_stack
log "sending 40 requests to a limit-20 endpoint across 2 replicas"
out="$RESULTS/ratelimit.txt"
: >"$out"
for _ in $(seq 40); do
  curl -s -o /dev/null -D - "$BASE_URL/api/limited" |
    awk 'NR==1 {code=$2} tolower($1)=="x-served-by:" {host=$2} END {gsub("\r","",host); print code, host}' >>"$out"
done

ok="$(grep -c '^200 ' "$out" || true)"
limited="$(grep -c '^429 ' "$out" || true)"
replicas="$(awk '{print $2}' "$out" | sort -u | wc -l | tr -d ' ')"
echo "  200 responses   $ok"
echo "  429 responses   $limited"
echo "  replicas used   $replicas"

[ "$replicas" -ge 2 ] || fail "requests did not spread across replicas"
[ "$ok" = "20" ] && [ "$limited" = "20" ] || fail "expected 20 allowed and 20 limited"
pass "rate limit is shared across replicas"
