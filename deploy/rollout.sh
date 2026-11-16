#!/usr/bin/env bash
# Zero-downtime rollout for one Compose service.
#
#   APP_TAG=v2 ./rollout.sh
#
# 1. run migrations (they must be backward compatible)
# 2. start NEW replicas next to the old ones
# 3. wait until every new replica is healthy; if not, remove them and exit 1
#    (the old replicas were never touched, so that is the rollback)
# 4. wait until the proxy is routing to the new replicas
# 5. stop the old replicas gracefully: they drain, then exit
#
# Env: APP_TAG (required), SERVICE=api, HEALTH_TIMEOUT=60, STOP_TIMEOUT=35,
#      TRAEFIK_API=http://127.0.0.1:8081, PULL=0 (1 = pull the image first)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

: "${APP_TAG:?set APP_TAG to the image tag to roll out}"
export APP_TAG
SERVICE="${SERVICE:-api}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-60}"
STOP_TIMEOUT="${STOP_TIMEOUT:-35}"
TRAEFIK_API="${TRAEFIK_API:-http://127.0.0.1:${DASHBOARD_PORT:-8081}}"

say() { printf '[rollout] %s\n' "$*"; }

old_ids="$(docker compose ps -q "$SERVICE")"
if [ -z "$old_ids" ]; then
  say "no running $SERVICE replicas: plain start"
  docker compose up -d --wait "$SERVICE"
  exit 0
fi
scale="$(printf '%s\n' "$old_ids" | wc -l | tr -d ' ')"

if [ "${PULL:-0}" = "1" ]; then
  say "pulling image for tag $APP_TAG"
  docker compose pull -q "$SERVICE" migrate
fi

say "running migrations with tag $APP_TAG"
docker compose run --rm --no-deps migrate

say "starting $scale new replica(s) with tag $APP_TAG next to $scale old"
# --no-recreate keeps the old replicas exactly as they are; only the extra
# ones are created, and they get the new image.
docker compose up -d --no-deps --no-recreate --scale "$SERVICE=$((scale * 2))" "$SERVICE"

new_ids="$(docker compose ps -q "$SERVICE" | grep -vxF -f <(printf '%s\n' "$old_ids") || true)"
if [ -z "$new_ids" ]; then
  say "ERROR: no new replicas were created"
  exit 1
fi

rollback() {
  say "ROLLBACK: $1"
  for id in $new_ids; do
    say "last log lines of ${id:0:12}:"
    docker logs --tail 5 "$id" 2>&1 | sed 's/^/    /' || true
  done
  # shellcheck disable=SC2086
  docker rm -f $new_ids >/dev/null
  say "new replicas removed; the old version never stopped serving"
  exit 1
}

say "waiting up to ${HEALTH_TIMEOUT}s for new replicas to become healthy"
deadline=$((SECONDS + HEALTH_TIMEOUT))
while :; do
  pending=0
  for id in $new_ids; do
    state="$(docker inspect -f '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id" 2>/dev/null || echo gone)"
    case "$state" in
      running/healthy) ;;
      running/starting) pending=1 ;;
      *) rollback "replica ${id:0:12} is $state" ;;
    esac
  done
  [ "$pending" = "0" ] && break
  [ "$SECONDS" -ge "$deadline" ] && rollback "new replicas not healthy after ${HEALTH_TIMEOUT}s"
  sleep 1
done
say "new replicas are healthy"

# Docker says healthy; now confirm the proxy has them in rotation before any
# old replica goes away.
want=$((scale * 2))
deadline=$((SECONDS + 30))
while :; do
  up="$(curl -fsS --max-time 2 "$TRAEFIK_API/api/http/services/$SERVICE@docker" 2>/dev/null |
    jq '[(.serverStatus // {})[] | select(. == "UP")] | length' 2>/dev/null || echo "")"
  if [ -n "$up" ] && [ "$up" -ge "$want" ]; then
    say "proxy is routing to all $up replicas"
    break
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    say "WARNING: could not confirm via proxy API (saw '${up:-no answer}', want $want); waiting 5s instead"
    sleep 5
    break
  fi
  sleep 1
done

say "stopping old replicas gracefully (they drain in-flight requests first)"
pids=""
for id in $old_ids; do
  docker stop -t "$STOP_TIMEOUT" "$id" >/dev/null &
  pids="$pids $!"
done
# shellcheck disable=SC2086
wait $pids
# shellcheck disable=SC2086
docker rm $old_ids >/dev/null

say "done: $SERVICE is now running tag $APP_TAG on $scale replica(s)"
