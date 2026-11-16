#!/usr/bin/env bash
# Shared helpers for the scenarios. Source it; do not run it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS="$ROOT/results"
mkdir -p "$RESULTS"

export PROXY_PORT="${PROXY_PORT:-8080}"
export DASHBOARD_PORT="${DASHBOARD_PORT:-8081}"
BASE_URL="${BASE_URL:-http://127.0.0.1:$PROXY_PORT}"

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() {
  printf '\n\033[31mFAIL: %s\033[0m\n' "$*"
  exit 1
}

compose() { (cd "$ROOT/deploy" && docker compose "$@"); }

build_image() {
  docker build -q -t "zdd-app:$1" --build-arg "VERSION=$1" "$ROOT/app" >/dev/null
}

# Fresh stack on v1: 2 API replicas, 1 worker, empty database.
reset_stack() {
  log "fresh stack on v1 (proxy on port $PROXY_PORT)"
  compose down -v --remove-orphans >/dev/null 2>&1 || true
  build_image v1
  build_image v2
  APP_TAG=v1 compose up -d --wait --quiet-pull 2>&1 | grep -vE 'Waiting|Healthy|Creat|Start|Exited|Pull' || true
  local deadline=$((SECONDS + 60))
  until [ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/api/version")" = "200" ]; do
    [ "$SECONDS" -ge "$deadline" ] && fail "stack did not come up on $BASE_URL"
    sleep 1
  done
}

# start_load NAME DURATION EXPECT_VERSIONS: k6 in the background.
start_load() {
  LOAD_NAME="$1"
  local duration="$2" expect="$3"
  LOAD_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local args=(run --quiet --summary-export "results/$LOAD_NAME.summary.json"
    -e "DURATION=$duration" -e "EXPECT_VERSIONS=$expect" -e "RATE=${RATE:-100}")
  log "load: ${RATE:-100} req/s + slow requests for $duration"
  if command -v k6 >/dev/null 2>&1; then
    (cd "$ROOT" && k6 "${args[@]}" -e "BASE_URL=$BASE_URL" loadtest/deploy-under-load.js) \
      >"$RESULTS/$LOAD_NAME.k6.txt" 2>&1 &
  else
    # No local k6: run it in a container that reaches the proxy on the host.
    docker run --rm --add-host=host.docker.internal:host-gateway -u "$(id -u)" \
      -v "$ROOT:/work" -w /work grafana/k6 "${args[@]}" \
      -e "BASE_URL=http://host.docker.internal:$PROXY_PORT" loadtest/deploy-under-load.js \
      >"$RESULTS/$LOAD_NAME.k6.txt" 2>&1 &
  fi
  LOAD_PID=$!
}

# finish_load [ok|report]: wait for k6, then give the verdict.
#   ok      (default) fail unless the client saw zero errors AND the proxy
#           logged zero error responses (4xx/5xx)
#   report  print the numbers but do not fail on them
finish_load() {
  local mode="${1:-ok}" rc=0
  log "waiting for the load test to finish"
  wait "$LOAD_PID" || rc=$?

  # Second, independent measurement: what the proxy itself logged.
  local proxy_log="$RESULTS/$LOAD_NAME.proxy.jsonl"
  compose logs --no-log-prefix --since "$LOAD_START" traefik 2>/dev/null |
    jq -Rc 'fromjson? | select(.DownstreamStatus != null and .entryPointName == "web")' >"$proxy_log" || true
  local total five
  total="$(wc -l <"$proxy_log" | tr -d ' ')"
  # Anything that is not a success counts: 5xx, and also the 404 the proxy
  # answers when no replica is registered at all.
  five="$(jq -c 'select(.DownstreamStatus >= 400)' "$proxy_log" | wc -l | tr -d ' ')"

  local s="$RESULTS/$LOAD_NAME.summary.json"
  echo "client (k6):"
  if [ -f "$s" ]; then
    jq -r '"  requests          \(.metrics.http_reqs.count)",
           "  failed requests   \(.metrics.http_req_failed.passes // "?")",
           "  failed checks     \(.metrics.checks.fails // "?")",
           "  p95 latency       \(.metrics.http_req_duration["p(95)"] | floor) ms"' "$s"
    jq -r '.metrics | to_entries[] | select(.key | startswith("served_by_version{"))
           | "  \(.key | sub("served_by_version";"served by ")) \(.value.count)"' "$s"
  else
    echo "  (no summary written, see $RESULTS/$LOAD_NAME.k6.txt)"
  fi
  echo "proxy (Traefik access log):"
  echo "  requests          $total"
  echo "  error responses   $five"
  if [ "$five" != "0" ]; then
    jq -r '"\(.DownstreamStatus) \(.RequestPath)"' <(jq -c 'select(.DownstreamStatus >= 400)' "$proxy_log") |
      sort | uniq -c | sed 's/^/    /'
  fi

  LOAD_RC="$rc"
  LOAD_ERRORS="$five"
  if [ "$mode" = "ok" ]; then
    if [ "$rc" != "0" ]; then
      grep -E '✗|level=error|threshold' "$RESULTS/$LOAD_NAME.k6.txt" | head -10 || true
      fail "load test saw errors (k6 exit $rc)"
    fi
    [ "$five" = "0" ] || fail "proxy logged $five error responses"
  fi
}

pass() { printf '\n\033[32mPASS: %s\033[0m\n' "$*"; }

api_versions() {
  # shellcheck disable=SC2046
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' $(compose ps -q api) |
    grep '^VERSION=' | sort | uniq -c | awk '{printf "%s%sx%s", sep, $1, $2; sep=" "}'
}
