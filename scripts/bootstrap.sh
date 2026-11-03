#!/usr/bin/env bash
# bootstrap.sh — install the OpenShift CMA / Minecraft workshop end-to-end.
#
# Reads ${NAMESPACE} from the environment (default: minecraft) and substitutes
# it into every YAML in manifests/ via envsubst before applying. Only the
# ${NAMESPACE} variable is expanded — any other ${...} that happens to appear
# in a manifest is left alone.
#
# Usage:
#   ./scripts/bootstrap.sh                                  # defaults: NAMESPACE=minecraft, TRIGGER=metrics-api
#   NAMESPACE=acme TRIGGER=prometheus ./scripts/bootstrap.sh
#   ./scripts/bootstrap.sh --dry-run                        # render-only, no oc apply
#   ./scripts/bootstrap.sh --uninstall                      # remove the per-namespace install (keeps the namespace)
#   ./scripts/bootstrap.sh --uninstall --delete-namespace   # also `oc delete project $NAMESPACE`
#   ./scripts/bootstrap.sh --skip-build                     # skip the in-cluster `make ocp-build`
#   ./scripts/bootstrap.sh --skip-seed                      # skip seeding the world data into the PVC
#   ./scripts/bootstrap.sh --force-seed                     # overwrite an existing world in the PVC
#
# Prerequisites (not enforced by this script):
#   * oc logged in with rights to create namespaces and cluster-scoped objects
#   * envsubst (ships with gettext on most distros)
#   * the Custom Metrics Autoscaler Operator already installed (OperatorHub)
#   * the mc-waker image already built and pushed/imagestreamed somewhere
#     reachable from the chosen namespace

set -euo pipefail

# ---- defaults -----------------------------------------------------------
: "${NAMESPACE:=minecraft}"
: "${TRIGGER:=metrics-api}"     # metrics-api | prometheus
: "${MC_WAIT_TIMEOUT:=180s}"
: "${WAKER_WAIT_TIMEOUT:=120s}"
: "${SEED_WAIT_TIMEOUT:=300s}"
export NAMESPACE

# world-seeding knobs (WORLD_TARBALL default is set after REPO_ROOT below)
: "${WORLD_LEVEL:=ragnarok}"        # must match LEVEL in the mc-ragnarok (Java) container
: "${SEED_HELPER_IMAGE:=docker.io/itzg/minecraft-server:latest}"
SEED_HELPER_POD="mc-ragnarok-seed"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"
MANIFESTS="$REPO_ROOT/manifests"
: "${WORLD_TARBALL:=$REPO_ROOT/mc-data/mc-ragnarok-data.tar.gz}"
# Tarball is not committed: fetched once from the GitHub Release when missing.
: "${WORLD_URL:=https://github.com/CSA-RH/openshift-cma-minecraft/releases/download/world-v1/mc-ragnarok-data.tar.gz}"
: "${WORLD_SHA256:=0d49a056aab00b774608618b42eca2c2887885ad3e747f9189af001ffb64ad6d}"

DRY_RUN=0
UNINSTALL=0
DELETE_NS=0
SKIP_BUILD=0
SKIP_SEED=0
FORCE_SEED=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)   DRY_RUN=1 ;;
    --uninstall)        UNINSTALL=1 ;;
    --delete-namespace) DELETE_NS=1 ;;
    --skip-build)       SKIP_BUILD=1 ;;
    --skip-seed)        SKIP_SEED=1 ;;
    --force-seed)       FORCE_SEED=1 ;;
    -h|--help)   sed -n '2,24p' "$0"; exit 0 ;;
    *)           echo "unknown arg: $arg (try --help)"; exit 1 ;;
  esac
done

# ---- helpers -----------------------------------------------------------
note()  { printf "\n\033[1;34m==>\033[0m %s\n" "$*"; }
warn()  { printf "\n\033[1;33mwarn:\033[0m %s\n" "$*" >&2; }
fatal() { printf "\n\033[1;31mfatal:\033[0m %s\n" "$*" >&2; exit 1; }

require() {
  command -v "$1" >/dev/null 2>&1 || fatal "$1 not found in PATH"
}

# render <yaml-file>: substitute only ${NAMESPACE}, leave all other ${...} alone
render() {
  envsubst '${NAMESPACE}' < "$1"
}

# apply <yaml-file-or-dir>: render every file (or every file in the dir) and pipe to oc apply -n $NAMESPACE
apply_namespaced() {
  local target="$1"
  if [[ -d "$target" ]]; then
    for f in "$target"/*.yaml; do apply_namespaced "$f"; done
    return
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "--- rendered $target ---"
    render "$target"
  else
    render "$target" | oc -n "$NAMESPACE" apply -f -
  fi
}

# apply_cluster <yaml-file>: same idea, but no -n flag (cluster-scoped or pre-namespaced)
apply_cluster() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "--- rendered $1 ---"
    render "$1"
  else
    render "$1" | oc apply -f -
  fi
}

# world_already_seeded_via_running_pod: returns 0 if /data/$WORLD_LEVEL/level.dat
# already exists inside a RUNNING mc-ragnarok container. A cheap rerun check
# that lets us skip the whole helper dance (and any scale churn) when the
# world is already in place.
world_already_seeded_via_running_pod() {
  oc -n "$NAMESPACE" get deploy/mc-ragnarok >/dev/null 2>&1 || return 1
  local pod
  pod="$(oc -n "$NAMESPACE" get pod -l app=mc-ragnarok \
          -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null \
          | awk '{print $1}')"
  [[ -n "$pod" ]] || return 1
  oc -n "$NAMESPACE" exec "$pod" -c mc-ragnarok -- \
     test -f "/data/$WORLD_LEVEL/level.dat" >/dev/null 2>&1
}

# fetch_world_tarball: download $WORLD_URL to $WORLD_TARBALL and check it
# against $WORLD_SHA256. Leaves no partial file behind on failure.
fetch_world_tarball() {
  note "Downloading world tarball from $WORLD_URL"
  local tmp="$WORLD_TARBALL.part" sum
  mkdir -p "$(dirname "$WORLD_TARBALL")"
  if ! curl -fsSL -o "$tmp" "$WORLD_URL"; then
    rm -f "$tmp"; return 1
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sum="$(sha256sum "$tmp" | cut -d' ' -f1)"
  else
    sum="$(shasum -a 256 "$tmp" | cut -d' ' -f1)"
  fi
  if [[ "$sum" != "$WORLD_SHA256" ]]; then
    warn "sha256 mismatch for downloaded tarball (got $sum)"
    rm -f "$tmp"; return 1
  fi
  mv "$tmp" "$WORLD_TARBALL"
}

# seed_world: extract $WORLD_TARBALL into /data/$WORLD_LEVEL on the
# mc-ragnarok-datadir PVC using a throwaway helper pod. The PVC is
# ReadWriteOnce and the server generates a fresh world on first boot, so we
# must seed while nothing else holds the volume — hence this runs before the
# Minecraft Deployment is (re)applied. Idempotent: skips if the world is
# already present unless --force-seed is given.
seed_world() {
  if [[ "$SKIP_SEED" -eq 1 ]]; then
    note "Skipping world seed (--skip-seed)"
    return 0
  fi
  if [[ ! -f "$WORLD_TARBALL" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "(would download $WORLD_URL to $WORLD_TARBALL and verify sha256)"
    elif ! fetch_world_tarball; then
      warn "Could not download a valid world tarball from $WORLD_URL — skipping seed."
      return 0
    fi
  fi

  note "Seeding world '$WORLD_LEVEL' from $(basename "$WORLD_TARBALL")"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "(would ensure PVC mc-ragnarok-datadir, then extract $(basename "$WORLD_TARBALL") into /data/$WORLD_LEVEL via helper pod '$SEED_HELPER_POD')"
    return 0
  fi

  # Cheap rerun short-circuit (no scale churn when already seeded).
  if [[ "$FORCE_SEED" -eq 0 ]] && world_already_seeded_via_running_pod; then
    note "World already present (found /data/$WORLD_LEVEL/level.dat) — skipping. Use --force-seed to overwrite."
    return 0
  fi

  # Make sure the target PVC exists before anything mounts it.
  apply_namespaced "$MANIFESTS/minecraft/mc-ragnarok-pvc.yaml"

  # ReadWriteOnce: free the volume by scaling the Minecraft Deployment to 0
  # (if it exists) and waiting for the pod to terminate.
  if oc -n "$NAMESPACE" get deploy/mc-ragnarok >/dev/null 2>&1; then
    note "Scaling deploy/mc-ragnarok to 0 to free the ReadWriteOnce PVC"
    oc -n "$NAMESPACE" scale deploy/mc-ragnarok --replicas=0
    oc -n "$NAMESPACE" wait --for=delete pod -l app=mc-ragnarok \
       --timeout="$SEED_WAIT_TIMEOUT" || true
  fi

  # Throwaway helper pod that mounts the PVC. Same image as the Java
  # container, so the user/permission model matches and tar+gzip are present.
  oc -n "$NAMESPACE" delete pod "$SEED_HELPER_POD" --ignore-not-found >/dev/null 2>&1 || true
  note "Launching seed helper pod '$SEED_HELPER_POD'"
  cat <<EOF | oc -n "$NAMESPACE" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $SEED_HELPER_POD
  labels:
    app.kubernetes.io/name: mc-ragnarok-seed
    app.kubernetes.io/part-of: mc-ragnarok
spec:
  restartPolicy: Never
  containers:
    - name: seed
      image: $SEED_HELPER_IMAGE
      command: ["bash","-c","exec sleep 1200"]
      volumeMounts:
        - { mountPath: /data, name: datadir }
  volumes:
    - name: datadir
      persistentVolumeClaim:
        claimName: mc-ragnarok-datadir
EOF

  oc -n "$NAMESPACE" wait --for=condition=Ready "pod/$SEED_HELPER_POD" \
     --timeout="$SEED_WAIT_TIMEOUT"

  # In-volume idempotency guard (covers "world present but server was down").
  if [[ "$FORCE_SEED" -eq 0 ]] \
     && oc -n "$NAMESPACE" exec "$SEED_HELPER_POD" -- \
        test -f "/data/$WORLD_LEVEL/level.dat" >/dev/null 2>&1; then
    note "World already present in PVC — skipping extraction (use --force-seed to overwrite)."
  else
    if [[ "$FORCE_SEED" -eq 1 ]]; then
      warn "--force-seed: removing any existing /data/$WORLD_LEVEL first"
      oc -n "$NAMESPACE" exec "$SEED_HELPER_POD" -- bash -c "rm -rf '/data/$WORLD_LEVEL'"
    fi
    note "Streaming + extracting world into /data/$WORLD_LEVEL"
    oc -n "$NAMESPACE" exec -i "$SEED_HELPER_POD" -- bash -c \
      "mkdir -p '/data/$WORLD_LEVEL' && tar xzf - -C '/data/$WORLD_LEVEL' && chmod -R g+rwX '/data/$WORLD_LEVEL'" \
      < "$WORLD_TARBALL"
    note "World seeded into /data/$WORLD_LEVEL."
  fi

  # Release the PVC. The Minecraft workload apply right after this resets
  # replicas to 1 (per the manifest) and rolls the server out onto the world.
  oc -n "$NAMESPACE" delete pod "$SEED_HELPER_POD" --ignore-not-found
  oc -n "$NAMESPACE" wait --for=delete "pod/$SEED_HELPER_POD" \
     --timeout="$SEED_WAIT_TIMEOUT" || true
}

# ---- preflight ---------------------------------------------------------
require oc
require envsubst

if [[ "$UNINSTALL" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
  oc whoami >/dev/null 2>&1 || fatal "not logged into an OpenShift cluster (try: oc login ...)"
fi

case "$TRIGGER" in
  metrics-api|prometheus) ;;
  *) fatal "TRIGGER must be 'metrics-api' or 'prometheus' (got: $TRIGGER)" ;;
esac

note "config: NAMESPACE=$NAMESPACE  TRIGGER=$TRIGGER  DRY_RUN=$DRY_RUN  UNINSTALL=$UNINSTALL"

# ---- uninstall path ----------------------------------------------------
if [[ "$UNINSTALL" -eq 1 ]]; then
  note "Tearing down resources from '$NAMESPACE'"
  oc delete -n "$NAMESPACE" -f "$MANIFESTS/keda/scaledobject-metricsapi.yaml" --ignore-not-found
  oc delete -n "$NAMESPACE" -f "$MANIFESTS/keda/scaledobject-prometheus.yaml" --ignore-not-found
  oc delete -n "$NAMESPACE" route mc-ragnarok-waker                           --ignore-not-found
  oc delete -n "$NAMESPACE" -f "$MANIFESTS/waker/"                            --ignore-not-found
  oc delete -n "$NAMESPACE" -f "$MANIFESTS/minecraft/"                        --ignore-not-found
  oc delete -n "$NAMESPACE" pod mc-ragnarok-seed --ignore-not-found # remove a leftover seed helper pod, if any
  oc delete -n "$NAMESPACE" all -l build=mc-waker --ignore-not-found # to Delete all the buildConfig related resources (buildConfig,builds and imageStream)

  if [[ "$DELETE_NS" -eq 1 ]]; then
    note "Deleting project '$NAMESPACE' (because --delete-namespace was passed)"
    oc delete project "$NAMESPACE" --ignore-not-found
  else
    note "Namespace '$NAMESPACE' kept (pass --delete-namespace to remove it too)"
  fi
  warn "Cluster-scoped KedaController in 'openshift-keda' was left alone — delete it manually if you no longer want CMA on this cluster."
  exit 0
fi

# ---- install path ------------------------------------------------------

# 0) KedaController (cluster-scoped, pinned to openshift-keda; one-time)
note "Applying KedaController (cluster-scoped, openshift-keda)"
apply_cluster "$MANIFESTS/keda/kedacontroller.yaml"

# 1) Namespace
note "Ensuring namespace '$NAMESPACE' exists"
if [[ "$DRY_RUN" -eq 0 ]]; then
  oc get ns "$NAMESPACE" >/dev/null 2>&1 || oc new-project "$NAMESPACE" >/dev/null
fi

# 2) Build the waker image into the namespace's ImageStream (in-cluster).
#    Skip with --skip-build if you've already pushed it (e.g. to quay.io)
#    and updated `image:` in manifests/waker/mc-waker.yaml accordingly.
if [[ "$SKIP_BUILD" -eq 1 ]]; then
  note "Skipping waker image build (--skip-build was passed)"
elif [[ "$DRY_RUN" -eq 1 ]]; then
  note "Would build waker image: make -C $REPO_ROOT/build/mc-waker ocp-build NAMESPACE=$NAMESPACE"
else
  note "Building waker image into ImageStream '$NAMESPACE/mc-waker' (in-cluster build)"
  make -C "$REPO_ROOT/build/mc-waker" ocp-build NAMESPACE="$NAMESPACE"
fi

# 2.5) Seed the world data into the PVC (first-time only; idempotent).
#      Runs before the Deployment is (re)applied so the ReadWriteOnce PVC is
#      free and the server boots straight onto the seeded world.
seed_world

# 3) Minecraft workload (secrets, PVC, deploy, services)
note "Applying Minecraft workload"
apply_namespaced "$MANIFESTS/minecraft"

if [[ "$DRY_RUN" -eq 0 ]]; then
  oc -n "$NAMESPACE" rollout status deploy/mc-ragnarok --timeout="$MC_WAIT_TIMEOUT"
fi

# 3) Waker (SA + Deployment + Service)
note "Applying waker"
apply_namespaced "$MANIFESTS/waker/mc-waker.yaml"

if [[ "$DRY_RUN" -eq 0 ]]; then
  oc -n "$NAMESPACE" rollout status deploy/mc-ragnarok-waker --timeout="$WAKER_WAIT_TIMEOUT"
fi

# 4.5) TLS-terminated Route for the waker's HTTP API (port 8080).
#      Hostname is derived from the cluster's base domain so curl works
#      from anywhere without a port-forward.
note "Creating edge-terminated Route for the waker API"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "(would create: route/mc-ragnarok-waker -> svc/mc-ragnarok-waker:8080 in $NAMESPACE)"
else
  BASE_DOMAIN="$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')"
  oc -n "$NAMESPACE" create route edge \
    --service=mc-ragnarok-waker \
    --port=8080 \
    --hostname="mc-ragnarok-waker-api.apps.${BASE_DOMAIN}" \
    --dry-run=client -o yaml \
    | oc -n "$NAMESPACE" apply -f -
  ROUTE_HOST="$(oc -n "$NAMESPACE" get route mc-ragnarok-waker -o jsonpath='{.spec.host}')"
  echo "    Route host: https://${ROUTE_HOST}"
fi

# 4) Trigger variant
case "$TRIGGER" in
  metrics-api)
    note "Applying ScaledObject (metrics-api trigger)"
    apply_namespaced "$MANIFESTS/keda/scaledobject-metricsapi.yaml"
    ;;
  prometheus)
    note "Provisioning Prometheus trigger auth (RBAC + token Secret)"
    if [[ "$DRY_RUN" -eq 0 ]]; then
      "$SCRIPT_DIR/setup-trigger-auth.sh" "$NAMESPACE"
    else
      echo "(skipped in --dry-run: $SCRIPT_DIR/setup-trigger-auth.sh $NAMESPACE)"
    fi
    note "Applying ServiceMonitor + ScaledObject (prometheus trigger)"
    apply_namespaced "$MANIFESTS/waker/servicemonitor.yaml"
    apply_namespaced "$MANIFESTS/keda/scaledobject-prometheus.yaml"
    ;;
esac

note "Done. Workshop installed in namespace '$NAMESPACE' with trigger '$TRIGGER'."
if [[ "$DRY_RUN" -eq 0 ]]; then
  echo
  echo "Quick smoke test:"
  echo '  ROUTE="https://$(oc -n '''$NAMESPACE''' get route mc-ragnarok-waker -o jsonpath='{.spec.host}')" '
  echo '  curl -sk $ROUTE/scaler # This will show the current desired replicas value'
  echo '  curl -skX POST $ROUTE/wake # This will simulate the same api request that KEDA/CMA will do to trigger the autoscaler'
  echo '  curl -sk $ROUTE/status | jq # All the info that you can pull from the waker pod are here.'
  
oc -n minecraft get scaledobject mc-ragnarok   # ACTIVE=True within ~15s of a wake
oc -n minecraft get deploy mc-ragnarok         # READY=1/1 shortly after
fi
