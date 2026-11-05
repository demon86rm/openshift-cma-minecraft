# OpenShift Custom Metrics Autoscaler — Workshop

A hands-on workshop on the **OpenShift Custom Metrics Autoscaler** (CMA / KEDA). You'll scale a Minecraft server pod from **0 to 1 and back** based on player intent — a custom metric the workload itself can't possibly report while it's at zero replicas.

The Minecraft pod runs `itzg/minecraft-server` (Java Edition). Bedrock Edition is not supported: since 1.26 its clients connect only over NetherNet (WebRTC with Microsoft signaling), which the waker can neither detect nor proxy.

## What it teaches

- `ScaledObject` mechanics: `threshold` vs `activationThreshold`, `pollingInterval`, `cooldownPeriod`, `fallback`.
- Two trigger flavors side-by-side: **`metrics-api`** (direct HTTP scrape) and **`prometheus`** (UWM / Thanos).
- Why a custom metric for a scale-to-zero workload has to be *sourced from outside* the workload.

## How it works

```
Java client    ─►  NodePort  ─TCP─►  waker pod  ─TCP─►  mc-ragnarok pod
                  (always 1)   25565            25565    (0..1, KEDA-scaled)
                                       │
                                       └── publishes minecraft_desired_replicas (0/1) ──► ScaledObject
```

The **waker** is a small Go service that always listens on TCP `25565`. When `mc-ragnarok` is up, it transparently proxies the connection. When it's at zero replicas, it answers the Minecraft client's *Refresh* (Server List Ping) with a "Sleeping" entry and raises the metric to `1`; a bare TCP connect (load balancer health check, port scanner) does not wake it. KEDA picks that up, scales the Minecraft Deployment to `1`, and the next refresh gets the live server. After the last player leaves and `cooldownPeriod` elapses, KEDA scales it back to `0`.

Source walkthrough for the waker — the proxy paths, the probe loop, the metrics: **[`docs/mc-waker-internals.md`](docs/mc-waker-internals.md)**. For an architectural comparison with Knative / OpenShift Serverless: **[`docs/keda-vs-knative.md`](docs/keda-vs-knative.md)**.

## Repo layout

```
build/mc-waker/                    Go source for the waker + Containerfile + Makefile
mc-data/                           prebuilt world tarball (downloaded from the world-v1 Release, not committed)
manifests/
├── aws/                           NLB Service for ROSA / AWS (applied by hand, not by bootstrap.sh)
├── keda/                          KedaController + the two ScaledObject variants
├── minecraft/                     Deployment, PVC, Services, Secrets
└── waker/                         waker Deployment + ServiceMonitor
scripts/
├── bootstrap.sh                   one-shot installer (NAMESPACE/TRIGGER as env vars)
└── setup-trigger-auth.sh          (Prometheus path only) provisions the bearer-token Secret
docs/
├── mc-waker-internals.md          walkthrough of the Go program
└── keda-vs-knative.md             architectural comparison (talk track + reference tables)
```

## Prerequisites

- This project has been tested on OpenShift 4.21.14; other versions should be fine, mileage may vary.
- A user with cluster-admin privileges is needed for the initial install.
- The **Custom Metrics Autoscaler Operator** installed (OperatorHub → "Custom Metrics Autoscaler"). `bootstrap.sh` creates the `KedaController` but does not install the operator.
- For the Prometheus variant: cluster-wide [User Workload Monitoring](https://docs.openshift.com/container-platform/latest/observability/monitoring/enabling-monitoring-for-user-defined-projects.html) enabled.

## Build the waker image (manual / external registry)

`bootstrap.sh` runs `make ocp-build` for you, which pushes into the cluster's internal ImageStream. If you'd rather build locally and push to an external registry (quay.io, etc.):

```bash
cd build/mc-waker
make image IMG=quay.io/<you>/mc-waker:v0.1.0  &&  make push IMG=quay.io/<you>/mc-waker:v0.1.0
```

Update the `image:` field in `manifests/waker/mc-waker.yaml` to match, then run `./scripts/bootstrap.sh --skip-build`.

> The waker's Containerfile is a three-stage build: stage 1 compiles the Go binary on UBI go-toolset; stage 2 borrows the `mc-monitor` binary from `itzg/minecraft-server` (the same tool the Minecraft pod uses for its own liveness probe); stage 3 assembles both into a small UBI-micro runtime image. No separate `mc-monitor` release to track.

## Deploy

> Both Secrets in `manifests/minecraft/` ship with `CHANGEME!` placeholder values. Replace at least the Curseforge one if you want modpack downloads.

End-to-end install is one command:

```bash
# Defaults: NAMESPACE=minecraft, TRIGGER=metrics-api
./scripts/bootstrap.sh

# Override either:
NAMESPACE=acme TRIGGER=prometheus ./scripts/bootstrap.sh

# Render-only (no oc apply, useful for diff'ing or piping to oc diff):
./scripts/bootstrap.sh --dry-run

# Already pushed the waker image somewhere (and updated `image:` in
# manifests/waker/mc-waker.yaml)? Skip the in-cluster build:
./scripts/bootstrap.sh --skip-build

# Don't seed the prebuilt world (start from a freshly generated one):
./scripts/bootstrap.sh --skip-seed

# Re-seed, overwriting whatever world is already in the PVC:
./scripts/bootstrap.sh --force-seed
```

The script applies the `KedaController`, creates the namespace, runs `make ocp-build` to push the waker image into the namespace's ImageStream, seeds the prebuilt world into the PVC, applies the Minecraft + waker workloads, and applies the chosen `ScaledObject`. Run `./scripts/bootstrap.sh --help` to see every flag.

### World seeding

`mc-data/mc-ragnarok-data.tar.gz` is a prebuilt Java world (the `ragnarok` level). It is not committed: if missing, the script downloads it from the [`world-v1` Release](https://github.com/demon86rm/openshift-cma-minecraft/releases/tag/world-v1) and verifies its sha256 (override with `WORLD_URL` / `WORLD_SHA256`). On the first install the script extracts it into the `mc-ragnarok-datadir` PVC at `/data/ragnarok` **before** the server boots, so `mc-ragnarok` comes up on the workshop world instead of generating a fresh one. Because the PVC is `ReadWriteOnce`, seeding runs via a short-lived helper pod while the Deployment is scaled to zero — it never fights the running server for the volume. The step is idempotent: if a world is already present it is left untouched (skipped), unless you pass `--force-seed`. Use `--skip-seed` to start from a freshly generated world instead. Override the source archive or level name with the `WORLD_TARBALL` and `WORLD_LEVEL` env vars.

`mc-ragnarok` will scale to `0` within ~60s of being idle (configurable via the ScaledObject's `cooldownPeriod`).

## Test

`bootstrap.sh` creates a TLS-terminated Route in front of the waker's HTTP API, so no port-forward is needed. Grab the URL once, then hit `/scaler`, `/wake`, or `/status`:

```bash
ROUTE="https://$(oc -n minecraft get route mc-ragnarok-waker -o jsonpath='{.spec.host}')"

curl -s   "$ROUTE/scaler"        # {"value":0}  when sleeping, {"value":1} when awake
curl -sX POST "$ROUTE/wake"      # manual wake — flips the metric to 1
curl -s   "$ROUTE/status" | jq   # full state JSON (upstream health, wake_active, ...)

oc -n minecraft get scaledobject mc-ragnarok   # ACTIVE=True within ~15s of a wake
oc -n minecraft get deploy mc-ragnarok         # READY=1/1 shortly after
```

End-to-end:
- **Java client** — connect to `<node-ip>:<nodePort-tcp>`. First *Refresh* shows the sleeping MOTD; refresh again ~1 min later for the live server.
- **ROSA / ARO / other cloud clusters** — worker nodes are usually in private subnets, so the NodePort is unreachable from a laptop. Run `oc -n minecraft port-forward svc/mc-ragnarok-waker 25565:25565` and connect to `localhost:25565` (works wherever `oc` works). If other people must connect, create a cloud load balancer restricted to their IPs and connect to its address on 25565 (on ARO / GCP drop the `aws-load-balancer-type` annotation):
  ```bash
  export PLAYER_CIDR="$(curl -s https://checkip.amazonaws.com)/32"
  envsubst '$PLAYER_CIDR' < manifests/aws/mc-ragnarok-lb.yaml | oc -n minecraft apply -f -
  oc -n minecraft get svc mc-ragnarok-lb   # EXTERNAL-IP = hostname to use
  ```

## Tuning

CMA-side knobs live on the `ScaledObject` (`pollingInterval`, `cooldownPeriod`, `fallback`, the `behavior` block). Waker-side knobs are `WAKER_*` env vars in `manifests/waker/mc-waker.yaml` — the most demo-relevant is `WAKER_WAKE_HOLD` (default `3m`; drop to `30s` if you want to demo the cooldown faster).

## Cleanup

```bash
# Remove the workshop resources, keep the namespace (safe in shared projects):
./scripts/bootstrap.sh --uninstall

# Or, also delete the namespace itself:
./scripts/bootstrap.sh --uninstall --delete-namespace
```

The cluster-scoped `KedaController` (in `openshift-keda`) is left alone in either case — delete it manually if you no longer want CMA on the cluster.

## References

- OpenShift docs — [Custom Metrics Autoscaler Operator](https://docs.openshift.com/container-platform/latest/nodes/cma/nodes-cma-autoscaling-custom.html)
- KEDA docs — [`ScaledObject` concepts](https://keda.sh/docs/latest/concepts/scaling-deployments/), [`metrics-api` trigger](https://keda.sh/docs/latest/scalers/metrics-api/), [`prometheus` trigger](https://keda.sh/docs/latest/scalers/prometheus/)
- itzg images — [`minecraft-server`](https://github.com/itzg/docker-minecraft-server), [`mc-monitor`](https://github.com/itzg/mc-monitor)
