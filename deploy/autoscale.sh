#!/usr/bin/env bash
# Autoscaler for one Compose service on one host.
#
#   METRIC=rps TARGET=60 ./autoscale.sh
#
# Every INTERVAL seconds:
#   1. measure the metric, averaged per replica
#   2. desired = ceil(replicas x metric / TARGET), kept within MIN..MAX
#      (the same formula the Kubernetes HPA uses)
#   3. scale UP at once; scale DOWN only when every reading in the last
#      SCALE_DOWN_WINDOW seconds agreed, so a short dip does not remove
#      replicas that are needed again a moment later
#
# Adding a replica is safe because the proxy ignores it until /ready passes.
# Removing one is safe because it drains before it exits. Both are the same
# mechanisms the rollout relies on.
#
# Env:
#   METRIC=rps             rps = requests/second per replica (from the proxy)
#                          cpu = CPU % per replica (from docker stats)
#   TARGET=60              the per-replica value to aim for
#   MIN_REPLICAS=2         never 1: a single replica cannot be replaced safely
#   MAX_REPLICAS=6         check database connections: replicas x pool size,
#                          and a rollout briefly doubles the replicas
#   INTERVAL=5             seconds between readings
#   SCALE_DOWN_WINDOW=60   seconds the load must stay low before scaling down
#   TOLERANCE=0.1          ignore a metric within 10% of TARGET
#   SERVICE=api, TRAEFIK_API=http://127.0.0.1:8081
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lock.sh
. ./lock.sh

SERVICE="${SERVICE:-api}"
METRIC="${METRIC:-rps}"
TARGET="${TARGET:-60}"
MIN_REPLICAS="${MIN_REPLICAS:-2}"
MAX_REPLICAS="${MAX_REPLICAS:-6}"
INTERVAL="${INTERVAL:-5}"
SCALE_DOWN_WINDOW="${SCALE_DOWN_WINDOW:-60}"
TOLERANCE="${TOLERANCE:-0.1}"
TRAEFIK_API="${TRAEFIK_API:-http://127.0.0.1:${DASHBOARD_PORT:-8081}}"

case "$METRIC" in rps | cpu) ;; *)
  echo "METRIC must be rps or cpu, got '$METRIC'" >&2
  exit 1
  ;;
esac

say() { printf '[autoscale] %s %s\n' "$(date -u +%H:%M:%S)" "$*"; }

trap lock_release EXIT
trap 'exit 0' INT TERM

# Total requests the proxy has sent to the service since it started.
requests_total() {
  curl -fsS --max-time 2 "$TRAEFIK_API/metrics" |
    awk -v s="service=\"$SERVICE@docker\"" \
      '/^traefik_service_requests_total/ && index($0, s) { sum += $NF } END { printf "%.0f", sum }'
}

# Sets $value to the metric averaged per replica, or fails if there is no
# reading yet. Call it directly, not in $(...): it has to remember the
# previous sample, and a subshell would forget it.
prev_total=""
prev_time=""
value=""
measure() {
  local ids="$1" count="$2"
  if [ "$METRIC" = "cpu" ]; then
    # shellcheck disable=SC2086
    value="$(docker stats --no-stream --format '{{.CPUPerc}}' $ids | tr -d '%' |
      awk '{ s += $1; n++ } END { if (!n) exit 1; printf "%.1f", s / n }')"
    return
  fi
  local total now last_total="$prev_total" last_time="$prev_time"
  total="$(requests_total)" || return 1
  now="$(jq -n 'now')"
  prev_total="$total"
  prev_time="$now"
  # A rate needs two samples. A lower total means the proxy restarted.
  [ -n "$last_total" ] && [ "$total" -ge "$last_total" ] || return 1
  value="$(awk -v d="$((total - last_total))" -v t0="$last_time" -v t1="$now" -v n="$count" \
    'BEGIN { if (t1 <= t0) exit 1; printf "%.1f", d / (t1 - t0) / n }')"
}

scale_to() {
  local ids="$1" from="$2" to="$3"
  if ! lock_try; then
    say "a rollout holds the lock, not scaling"
    return 0
  fi
  # Scale with the image that is running now, not the default tag, so a
  # scale-up after a rollout starts replicas of the current release.
  local image
  image="$(docker inspect -f '{{.Config.Image}}' "$(printf '%s\n' "$ids" | head -1)")"
  export APP_IMAGE="${image%:*}" APP_TAG="${image##*:}"

  say "scaling $from -> $to"
  local wait_flag=""
  # Scaling up: return only when the new replicas are healthy.
  [ "$to" -gt "$from" ] && wait_flag="--wait"
  # shellcheck disable=SC2086
  if ! docker compose up -d --no-deps --no-recreate --scale "$SERVICE=$to" $wait_flag "$SERVICE" >/dev/null 2>&1; then
    say "ERROR: scaling to $to failed"
  fi
  lock_release
}

say "watching $SERVICE: metric=$METRIC target=$TARGET per replica, replicas $MIN_REPLICAS..$MAX_REPLICAS, every ${INTERVAL}s, scale-down window ${SCALE_DOWN_WINDOW}s"

history="" # one "time desired" line per reading inside the scale-down window
while :; do
  sleep "$INTERVAL"

  if lock_busy; then
    say "a rollout is in progress, paused"
    prev_total=""
    continue
  fi

  ids="$(docker compose ps -q --status running "$SERVICE" 2>/dev/null || true)"
  [ -n "$ids" ] || continue
  current="$(printf '%s\n' "$ids" | wc -l | tr -d ' ')"

  measure "$ids" "$current" || continue

  desired="$(awk -v cur="$current" -v v="$value" -v target="$TARGET" -v tol="$TOLERANCE" \
    -v min="$MIN_REPLICAS" -v max="$MAX_REPLICAS" 'BEGIN {
      ratio = v / target
      d = cur
      if (ratio > 1 + tol || ratio < 1 - tol) {
        d = cur * ratio
        d = (d == int(d)) ? d : int(d) + 1
      }
      if (d < min) d = min
      if (d > max) d = max
      print d
    }')"

  # Act on the highest reading in the window: up at once, down only when
  # every reading in the window agrees.
  history="$(printf '%s\n%s %s\n' "$history" "$SECONDS" "$desired" |
    awk -v cutoff="$((SECONDS - SCALE_DOWN_WINDOW))" 'NF == 2 && $1 >= cutoff')"
  goal="$(printf '%s\n' "$history" | awk '$2 > m { m = $2 } END { print m }')"

  say "$METRIC/replica=$value replicas=$current desired=$desired"
  if [ "$goal" != "$current" ]; then
    scale_to "$ids" "$current" "$goal"
    prev_total="" # the next rate would span the scaling pause: start fresh
  fi
done
