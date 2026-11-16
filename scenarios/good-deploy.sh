#!/usr/bin/env bash
# Roll v1 -> v2 while traffic is flowing. Not one request may fail, and both
# versions must have served traffic (proof that the switch really happened).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

reset_stack
start_load good-deploy 50s v1,v2
sleep 8

log "rolling out v2 under load"
APP_TAG=v2 "$ROOT/deploy/rollout.sh"

finish_load
case "$(api_versions)" in
  "2xVERSION=v2") ;;
  *) fail "expected 2 replicas on v2, got: $(api_versions)" ;;
esac
pass "v1 -> v2 rolled out under load with zero failed requests"
