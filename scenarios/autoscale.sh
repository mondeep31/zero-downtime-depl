#!/usr/bin/env bash
# Autoscaling under load. The request rate goes low -> high -> low, and the
# autoscaler must follow it on its own:
#
#   - add replicas when requests/second per replica goes over the target
#   - remove them again once the load has stayed low
#   - not one request may fail while replicas come and go
#
# With TARGET=60 req/s per replica: 80 req/s needs 2 replicas (the minimum),
# 280 req/s needs 5.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOW="${LOW:-80}"
HIGH="${HIGH:-280}"
export TARGET="${TARGET:-60}" MIN_REPLICAS="${MIN_REPLICAS:-2}" MAX_REPLICAS="${MAX_REPLICAS:-6}"
# Peak the autoscaler should reach: ceil(HIGH / TARGET), capped at the maximum.
want_peak=$(((HIGH + TARGET - 1) / TARGET))
[ "$want_peak" -gt "$MAX_REPLICAS" ] && want_peak="$MAX_REPLICAS"

reset_stack

as_log="$RESULTS/autoscale.autoscaler.log"
timeline="$RESULTS/autoscale.replicas.txt"
log "starting the autoscaler: target $TARGET req/s per replica, $MIN_REPLICAS..$MAX_REPLICAS replicas"
METRIC=rps INTERVAL=3 SCALE_DOWN_WINDOW=20 "$ROOT/deploy/autoscale.sh" >"$as_log" 2>&1 &
AS_PID=$!
trap 'kill "$AS_PID" 2>/dev/null || true' EXIT

# 15s low, 40s high, 45s low. The 5s stages are the ramps between them.
STAGES="$LOW:15s,$HIGH:5s,$HIGH:35s,$LOW:5s,$LOW:45s" start_load autoscale 105s v1

# Independent record of the replica count, taken from Docker every 2 seconds.
: >"$timeline"
peak=0
while kill -0 "$LOAD_PID" 2>/dev/null; do
  n="$(compose ps -q --status running api | wc -l | tr -d ' ')"
  echo "$(date -u +%H:%M:%S) $n" >>"$timeline"
  [ "$n" -gt "$peak" ] && peak="$n"
  sleep 2
done

finish_load
kill "$AS_PID" 2>/dev/null || true

echo "autoscaler decisions:"
grep -E 'scaling|ERROR' "$as_log" | sed 's/^/  /' || true
echo "replica count over time (from Docker):"
awk '$2 != last { printf "  %s  %s replicas\n", $1, $2; last = $2 }' "$timeline"

if grep -q ERROR "$as_log"; then fail "the autoscaler reported an error, see $as_log"; fi
[ "$peak" -ge "$want_peak" ] || fail "expected a peak of $want_peak replicas at $HIGH req/s, saw $peak"
final="$(compose ps -q --status running api | wc -l | tr -d ' ')"
[ "$final" = "$MIN_REPLICAS" ] || fail "expected $MIN_REPLICAS replicas after the load dropped, got $final"
pass "autoscaled $MIN_REPLICAS -> $peak -> $final replicas following the load, with zero failed requests"
