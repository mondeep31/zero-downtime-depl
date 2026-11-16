# Zero-downtime deploys, proven under load

A small, runnable reference for deploying a containerised API on **one server**
without dropping a single request, plus the tests that prove it.

- **Stack:** Docker Compose, Traefik, a Go API, Postgres, Redis.
- **Proof:** every scenario runs while k6 sends 100 requests/second. A scenario
  fails if one request fails.

```
make test
```

| Scenario | What happens under load | Result that passes |
|---|---|---|
| `good-deploy` | Roll v1 to v2 | 0 failed requests, both versions served traffic |
| `bad-deploy` | Roll out a release that never becomes ready | Rollout aborts, 0 failed requests, broken release served nothing |
| `scale` | Scale 2 to 4 to 2 replicas | 0 failed requests |
| `ratelimit` | 40 requests against a limit of 20, across 2 replicas | Exactly 20 allowed (state is shared, not per replica) |
| `kill-container` | One replica crashes instantly | Only requests in flight inside it are lost; it restarts and rejoins |
| `naive-deploy` | Control: plain `docker compose up -d` with a new tag | **Must lose requests**, which proves the test detects downtime |

Typical numbers from one run on a laptop:

| Scenario | Requests | Failed |
|---|---|---|
| `good-deploy` | 5,087 | 0 |
| `bad-deploy` | 6,101 | 0 |
| `scale` | 5,087 | 0 |
| `kill-container` | 4,072 | 3 |
| `naive-deploy` (control) | 4,607 | 851 |

## How it works

```
                     ┌──────────── one server ─────────────┐
                     │                                     │
  clients ──────────►│  Traefik ──► api (replica 1)  ──┐   │
                     │     │   └──► api (replica 2)  ──┼─► Postgres
                     │     │                           ├─► Redis
                     │     └ routes only to replicas   │   │
                     │       that pass GET /ready      │   │
                     │                                 │   │
                     │           worker (1 replica) ───┘   │
                     └─────────────────────────────────────┘
```

A rollout (`deploy/rollout.sh`) never stops anything until its replacement is
serving:

1. Run migrations. They must be backward compatible, because the old release
   is still serving.
2. Start new replicas **next to** the old ones.
3. Wait until every new replica is healthy. If that does not happen in time,
   remove the new replicas and exit non-zero. The old ones were never touched,
   so that is the rollback.
4. Wait until the proxy reports the new replicas in rotation.
5. Send SIGTERM to the old replicas. Each one fails its readiness check, keeps
   serving for a few seconds while the proxy stops routing to it, finishes its
   in-flight requests, and exits.

## Why deploys drop requests, and the fix for each

| Cause | What the client sees | Fix in this repo |
|---|---|---|
| Old stopped before new is up | 503/404 for seconds | Start new first (`rollout.sh`), at least 2 replicas |
| Traffic sent to an app that is still starting | 502/503, errors from a cold app | `/ready` gates traffic; Traefik ignores a container until Docker reports it healthy |
| Process killed with requests in flight | 502, connection reset | Graceful shutdown on SIGTERM (`app/http.go`) |
| Listener closed while the proxy still routes to it | 502 | Fail `/ready` first, keep serving for `SHUTDOWN_DELAY`, then close |
| App closes an idle keep-alive connection as the proxy reuses it | Random 502, also outside deploys | App idle timeout (120s) longer than the proxy's (90s) |
| Broken release rolled out everywhere | Full outage | Health-gated rollout that aborts and removes the new replicas |
| Schema change breaks the release still running | 500 during rollout | Migrations as a separate step, expand/contract only |
| State kept in process memory | Logged-out users, per-replica limits | Sessions and rate limits in Redis |
| Background job inside the API process | Job runs once per replica | Separate `worker` service, one replica, Redis lock |
| SIGTERM never reaches the app | Hard kill after the grace period | Exec-form `ENTRYPOINT`, so the app is PID 1 |

### The timings that matter

These four settings depend on each other. If you change one, check the rest.

| Setting | Where | Value | Rule |
|---|---|---|---|
| Proxy health check interval | `docker-compose.yml` label | 1s | Small, so a draining replica leaves rotation fast |
| `SHUTDOWN_DELAY` | api env | 4s | Longer than 2 health check intervals |
| `SHUTDOWN_TIMEOUT` | api env | 25s | Longer than your slowest request |
| `stop_grace_period` | `docker-compose.yml` | 35s | Longer than `SHUTDOWN_DELAY` + `SHUTDOWN_TIMEOUT` |

## Run it

Needs Docker with Compose v2, `make`, `jq` and `curl`. k6 is optional: without
it, the scenarios run k6 from its Docker image.

```bash
make up                  # build v1, start the stack on http://127.0.0.1:8080
curl -i http://127.0.0.1:8080/api/version

make deploy TAG=v2       # roll out a new version with zero downtime
make test                # run every scenario (about 6 minutes)
make test-good-deploy    # or just one
make down                # stop and delete the data
```

Ports 8080 (proxy) and 8081 (Traefik dashboard, localhost only) are the
defaults. Change them with `PROXY_PORT=9080 DASHBOARD_PORT=9081 make test`.
On a machine with a public address, add `PROXY_BIND=127.0.0.1` so the demo
stack is not reachable from outside.

### Reading a result

```
client (k6):
  requests          5087
  failed requests   0            <- what clients experienced
  failed checks     0
  p95 latency       3 ms
  served by {version:v1} 1299    <- traffic really moved from v1 ...
  served by {version:v2} 3787    <- ... to v2
proxy (Traefik access log):
  requests          5088
  error responses   0            <- the same thing, measured on the server side
```

Two independent measurements have to agree: what k6 saw, and what the proxy
logged. Raw output is kept in `results/`.

## Layout

```
app/          demo service: http, worker and migrate modes in one binary
deploy/       docker-compose.yml and rollout.sh
loadtest/     k6 script
scenarios/    one script per scenario, plus shared helpers in lib.sh
.github/      CI that runs every scenario; an example deploy pipeline
```

Endpoints of the demo service:

| Endpoint | Purpose |
|---|---|
| `GET /health` | Liveness: the process is up. Checks nothing else. |
| `GET /ready` | Readiness: warm-up done, Postgres and Redis reachable, not draining |
| `POST /login` | Creates a session in Redis (`demo` / `demo`) |
| `GET /api/items` | Authenticated read from Postgres |
| `GET /api/version` | Which version and replica answered |
| `GET /api/limited` | Rate limited through a shared Redis counter |
| `GET /slow?ms=` | Test hook: holds a request open (only with `TEST_HOOKS=true`) |

## CI

`.github/workflows/sync-to-server.yml` only puts the code on the test server.
On every push to `main` (or when started by hand), a self-hosted runner on that
server copies the repo into `~/zero-downtime-deploy`. `results/` is left alone,
so results from earlier runs survive a sync. The tests are then run by hand on
the server:

```bash
cd ~/zero-downtime-deploy
cat .deployed-commit      # which commit is there
make test                 # or make test-<scenario>
```

The server needs Docker with Compose v2, `make`, `jq`, `curl` and `rsync`.
Install the runner as a service (`sudo ./svc.sh install <user>`, then
`sudo ./svc.sh start`) rather than leaving `./run.sh` in a terminal; jobs pushed
while the runner is offline sit queued and are eventually cancelled.

The workflow deliberately does not run on pull requests. On a public
repository, a pull request from a fork could otherwise run its own code on the
runner's machine.

`.github/workflows/deploy-example.yml` is a template for a real pipeline: build
the image, push it to a registry, SSH to the server, run `rollout.sh`. If the
new release never becomes healthy the script exits non-zero, the job fails, and
the old release is still serving.

## Using this for your own service

The demo app is only a stand-in. To adopt the approach, your service needs:

1. **Graceful shutdown.** On SIGTERM: fail readiness, wait, drain, exit.
2. **A real `/ready`** that checks what the app needs in order to answer
   correctly, and a cheap `/health` that checks nothing.
3. **No state in process memory** that another replica would need.
4. **Background jobs out of the API process.**
5. **Migrations as a separate, backward compatible step.**
6. **Connection limits that add up.** Database connections = replicas × pool
   size, and a rollout briefly doubles the replicas.

Then point `APP_IMAGE` at your image, adjust the environment in
`deploy/docker-compose.yml`, and run the scenarios against it.

## Limits

- **Crashes are not zero-loss.** A planned stop drains; a crash cannot.
  Requests in flight inside a replica that dies are lost. Everything else is
  retried on another replica. Clients should retry idempotent requests.
- **One server is one point of failure.** This removes downtime from
  *deploys*, not from hardware failure. That needs a second machine.
- **No autoscaling.** The `scale` scenario shows that changing the replica
  count is safe, which is the part an autoscaler relies on. Deciding *when* to
  scale needs an orchestrator such as Kubernetes, and adding real capacity
  needs more machines.
- **Retries cover connection failures only**, and Traefik will not replay a
  request that already reached a replica. That is deliberate: replaying a
  non-idempotent request could apply it twice.
- **The test hooks are for testing.** Run production with `TEST_HOOKS=false`
  and `FAIL_READY=false`, and do not expose the Traefik dashboard.
