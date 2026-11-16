#!/usr/bin/env bash
# CONTROL: deploy the way most people start out, `docker compose up -d` with a
# new tag. Compose stops the old containers and only then starts new ones, so
# for a few seconds nothing is serving.
#
# This scenario is EXPECTED to produce errors. It passes only if it does:
# that proves the load test really detects downtime, so the zero in the other
# scenarios means something.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

reset_stack
start_load naive-deploy 45s ""
sleep 8

log "naive deploy: docker compose up -d with the new tag (no rollout script)"
APP_TAG=v2 compose up -d --no-deps api 2>&1 | grep -E 'Recreated|Started' || true

finish_load report
[ "$LOAD_ERRORS" -gt 0 ] || [ "$LOAD_RC" != "0" ] ||
  fail "the naive deploy produced no errors: the load test is not detecting downtime"
pass "control confirmed: the naive deploy lost $LOAD_ERRORS requests, and the load test caught it"
