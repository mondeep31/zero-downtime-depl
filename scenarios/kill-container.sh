#!/usr/bin/env bash
# Crash test: one replica dies instantly mid-traffic. There is no graceful
# shutdown here, so this is NOT a zero-error scenario. It measures how small
# the damage is and checks that the system heals itself.
#
#   - Requests that had not reached the dead replica yet are retried by the
#     proxy on the other replica: no error.
#   - Requests already being processed inside it are lost (502). Nothing can
#     finish them. With 5 slow requests + 100 req/s that is a handful.
#   - Docker restarts the replica, and it rejoins once it is ready.
#
# MAX_LOST (default 10) is the most lost requests the scenario accepts.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
MAX_LOST="${MAX_LOST:-10}"

reset_stack
start_load kill-container 40s v1
sleep 10

victim="$(compose ps -q api | head -1)"
log "crashing replica ${victim:0:12} (process exits instantly, no drain)"
# The signal is sent from INSIDE the container, so Docker sees a real crash.
# `docker kill` would count as a manual stop and the restart policy would not
# apply.
docker exec "$victim" kill -USR1 1

finish_load report

deadline=$((SECONDS + 60))
until [ "$(docker inspect -f '{{.State.Health.Status}}' "$victim" 2>/dev/null)" = "healthy" ]; do
  [ "$SECONDS" -ge "$deadline" ] && fail "crashed replica did not come back healthy"
  sleep 1
done
restarts="$(docker inspect -f '{{.RestartCount}}' "$victim")"
echo "crashed replica was restarted by Docker (restart count: $restarts) and is healthy again"
[ "$restarts" -ge 1 ] || fail "expected Docker to have restarted the replica"

[ "$LOAD_ERRORS" -le "$MAX_LOST" ] || fail "$LOAD_ERRORS requests were lost (allowed: $MAX_LOST)"
pass "replica crash contained: $LOAD_ERRORS lost in-flight request(s) (allowed: $MAX_LOST), replica recovered"
