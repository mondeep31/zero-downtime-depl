# Production loop

What has to be true on the server once this stack is the real service, and the
work still left. Deploys and autoscaling already run. Logs, host metrics, and
the public HTTPS name do not.

The shape:

```
browser ──443──► Traefik ──► api replicas ──► Postgres
                    │              │              │
                    │              └── worker     └── Redis
                    │
                    └── stdout, /metrics
                            │
                     collector on this machine
                       (localhost scrapes only)
                            │
              ┌─────────────┴─────────────┐
              ▼                           ▼
           SigNoz                        S3
        search, graphs                 archive
```

SigNoz is the only place to look. S3 is the only archive. There is no Loki,
and there is no Prometheus server. Prometheus here is the text format the
exporters publish and the collector scrapes.

One collector per machine. This repo runs the API, the database, and Redis on
the same host, so one collector covers them. A database moved to its own
machine gets its own `node_exporter` and its own collector, pushing to the
same SigNoz.

## Already in this repo

| Piece | Where | State |
|---|---|---|
| Zero-downtime rollout | `deploy/rollout.sh` | Done. New replicas start beside the old ones, Traefik must report them `UP`, then the old ones drain. |
| Autoscaler | `deploy/autoscale.sh` | Done. `rps` per replica from Traefik, target 60, scale up immediately, scale down only after `SCALE_DOWN_WINDOW`. Shares `deploy/lock.sh` with the rollout. |
| Traefik metrics | `deploy/docker-compose.yml` | `--metrics.prometheus=true` on `127.0.0.1:8081/metrics`. The autoscaler reads it. Nothing ships it anywhere. |
| App logs | `app/main.go` | JSON to stdout via `slog`, with `version` and `mode`. Docker stores them. Nothing ships them. |
| Traefik access log | compose command | JSON to stdout. Each line has `ServiceAddr` (which replica answered), `RequestPath`, `DownstreamStatus`, `Duration`. |
| Local log cap | — | Not set. Docker's `json-file` driver grows without a limit until the container is removed. |
| Public name and TLS | — | Not set. The router is `PathPrefix(/)` on port 8080. |

`make test` stays on `http://127.0.0.1:8080`. The scenarios count Traefik
access-log lines on the entrypoint named `web`. A public 443 listener is added
beside that, not instead of it.

## 1. Public name

`api.abc.com` is a Traefik router label in `deploy/docker-compose.yml`. It does
not go in `app/Dockerfile`. The image stays a binary that listens on port 8080
inside the Docker network.

DNS is an A record from `api.abc.com` to this machine. Traefik does not look
that up.

On the Traefik service:

- entrypoint `websecure` on container port 443, published as host `443:443`
- port 80 redirects to it
- certificate for `api.abc.com` mounted from `deploy/certs/` and listed in
  `deploy/tls.yml` (`--providers.file.filename`)
- dashboard stays `127.0.0.1:8081`. The rollout reads backend health there.

On the `api` service, replace the catch-all router:

```yaml
- traefik.http.routers.api.rule=Host(`api.abc.com`)
- traefik.http.routers.api.entrypoints=websecure
- traefik.http.routers.api.tls=true
- traefik.http.routers.api.middlewares=api-retry
- traefik.http.services.api.loadbalancer.server.port=8080
```

Health checks, the retry middleware, and `server.port=8080` stay. A second
hostname on the same service is `Host(\`api.abc.com\`) || Host(\`api.example.org\`)`.
A second site is another service with its own router labels.

For the lab, keep the current `web` entrypoint on localhost port 8080 so
`make test` still has a URL. The public router is a second router on
`websecure`.

Work:

- [ ] Add `websecure`, the port-80 redirect, and `deploy/tls.yml`
- [ ] Mount the certificate. The name on the cert is `api.abc.com`
- [ ] Add the `Host` router without removing the localhost test entrypoint
- [ ] Confirm `https://api.abc.com/api/version` hits a healthy replica, and
      `make test` still passes against port 8080

## 2. Logs

Applications write one JSON object per line to stdout and exit. They do not
open log files, rotate them, or talk to SigNoz.

Every service this repo owns uses the same fields:

```json
{"time":"...","level":"INFO","msg":"...","service":"api","version":"v1","mode":"http"}
```

`service`, `version`, and `mode` are known inside the process. The collector
adds `container.name` (`zdd-api-1`, `zdd-worker-1`) and the host, which is what
separates the replicas. A `trace_id` logged by both Traefik and the app is how
an access-log line and the matching app line become one request. That field is
not logged today.

Postgres and Redis keep their own text. The collector files those lines by
container name and does not parse them into the app schema.

The collector on this host tails Docker's log files as they grow and sends
each line two places:

- SigNoz, OTLP to port 4317, for search. Retain 15 to 30 days, then delete.
- S3, in batches, as the line arrives. The bucket lifecycle moves older
  objects to colder storage. This copy is the archive. Logs are not copied
  out of SigNoz after they age out. By then SigNoz has deleted them.

### Rotation

Rotation is a disk cap on this machine, not the history. Set it on every
service:

```yaml
logging:
  driver: json-file
  options:
    max-size: "50m"
    max-file: "3"
```

At 50 MB Docker starts a new file and keeps three. The collector follows the
new file. Three files are a short buffer for a collector that is briefly down.
Traefik, Postgres, Redis, the worker, and an API replica that lives between
deploys are the containers this matters for.

A rollout ends in `docker rm` of the old replicas (`deploy/rollout.sh`). A
scale-down removes the extra API containers the same way. Docker deletes that
container's log file at removal. The collector has to have read it already.
Tailing continuously does this, because lines are shipped as they are written
and the drain takes several seconds. After `docker rm`, SigNoz and S3 are the
only record of that replica.

Work:

- [ ] Add `service` to the `slog` logger in `app/main.go`. `version` and `mode` are already there
- [ ] Set `max-size` / `max-file` on every compose service
- [ ] Run the collector on this host. Tail `/var/lib/docker/containers/*/*-json.log`, add container name and host
- [ ] Ship to SigNoz and to S3 from that collector
- [ ] Set SigNoz log retention and the S3 lifecycle rule
- [ ] During `make test-good-deploy`, confirm the removed replica's last shutdown line is in SigNoz after `docker rm`

## 3. Metrics

Exporters on this machine publish `/metrics`. The collector scrapes localhost
and pushes the samples to SigNoz over OTLP, on the same path as the logs.
Nothing outside the machine connects to these ports.

| Exporter | Bind | What it is |
|---|---|---|
| `node_exporter` | `127.0.0.1:9100` | CPU, RAM, disk, and network of the machine |
| cAdvisor | `127.0.0.1:8088` | CPU and RAM of each container |
| Traefik | `127.0.0.1:8081` | Request rate, latency, and which replicas are `UP`. Already enabled |
| `postgres_exporter` | `127.0.0.1:9187` | Connections, cache hit rate, database size |
| `redis_exporter` | `127.0.0.1:9121` | Memory, clients, commands per second |

Scrape every 15 seconds. The host running out of memory is a `node_exporter`
series. One API replica using a core is a cAdvisor series named
`zdd-api-1`. Those stay different graphs. Traefik's request counters are per
service (`api@docker`), not per container. Per-replica traffic is the access
log's `ServiceAddr`, and `traefik_service_server_up` only says whether that
address is in rotation.

The Go process does not export metrics yet. Request rate and latency come
from Traefik. App-level numbers (open database connections, in-flight
requests) need a `/metrics` endpoint on the API, scraped the same way, and
are a later change.

A second machine, when the database moves, runs `node_exporter` plus the
database exporter and its own collector. It pushes to the same SigNoz. It
does not open those ports to the API host.

Work:

- [ ] Add `node_exporter`, cAdvisor, `postgres_exporter`, and `redis_exporter`, each bound to localhost
- [ ] Point the collector at the five URLs above, including Traefik's existing `/metrics`
- [ ] Confirm SigNoz shows host RAM, per-container CPU, Traefik request rate, and Postgres connections
- [ ] Leave the autoscaler's scrape of `127.0.0.1:8081/metrics` as it is

## 4. What a deploy does to logs and metrics

1. `rollout.sh` takes `deploy/lock.sh`. The autoscaler pauses.
2. New API containers start. Their stdout is a new Docker log file. cAdvisor
   starts a new container series. Traefik leaves them out until `/ready` passes.
3. Old containers drain, exit, and are removed. Their log files disappear
   with them. Their cAdvisor series stops. The shipped lines stay in SigNoz
   and S3.
4. The lock is released. The autoscaler measures `rps` again from a fresh
   sample, so the rate does not span the deploy.

A scale-up is steps 2 and 4 without removing anything. A scale-down is step 3
for the extra replicas only. The collector does not need to know that a
deploy is happening.

## Work order

1. Log cap and the `service` field. Small, and the later checks depend on them.
2. Collector to SigNoz, logs and the five scrapes. Prove one deploy and one
   scale-down still leave the removed replica's logs searchable.
3. S3 archive and the two retention clocks (SigNoz days, bucket lifecycle).
4. Public `websecure` router for `api.abc.com`, beside the test entrypoint.
5. App `/metrics` only when Traefik's numbers are not enough.
