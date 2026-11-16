#!/usr/bin/env bash
# Deploy a broken release (it never becomes ready) while traffic is flowing.
# The rollout must give up and remove it, the old version must keep serving,
# and not one request may fail or reach the broken release.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

reset_stack
start_load bad-deploy 60s v1
sleep 8

log "rolling out a broken v2 under load (expecting the rollout to abort)"
rc=0
FAIL_READY=true APP_TAG=v2 HEALTH_TIMEOUT=30 "$ROOT/deploy/rollout.sh" || rc=$?
[ "$rc" != "0" ] || fail "rollout reported success for a release that never became ready"

finish_load
case "$(api_versions)" in
  "2xVERSION=v1") ;;
  *) fail "expected 2 replicas still on v1, got: $(api_versions)" ;;
esac
if jq -e '.metrics["served_by_version{version:v2}"].count > 0' "$RESULTS/bad-deploy.summary.json" >/dev/null 2>&1; then
  fail "the broken release served traffic"
fi
pass "broken release was rejected; v1 kept serving with zero failed requests"
