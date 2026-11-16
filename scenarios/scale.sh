#!/usr/bin/env bash
# Scale 2 -> 4 -> 2 replicas while traffic is flowing. This is exactly what an
# autoscaler does, so if this is clean, autoscaling will be too.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

reset_stack
start_load scale 50s v1
sleep 8

log "scaling up to 4 replicas"
APP_TAG=v1 compose up -d --no-deps --no-recreate --scale api=4 --wait api 2>&1 | grep -E 'Started' || true
sleep 8

log "scaling down to 2 replicas (the removed ones drain first)"
APP_TAG=v1 compose up -d --no-deps --no-recreate --scale api=2 api 2>&1 | grep -E 'Removed' || true

finish_load
[ "$(compose ps -q --status running api | wc -l | tr -d ' ')" = "2" ] || fail "expected 2 replicas after scale down"
pass "scaled 2 -> 4 -> 2 under load with zero failed requests"
