#!/usr/bin/env bash
# Runs an MLflow server on OpenShift, built from a branch of mlflow/mlflow. See README.md.
#
#   ./mlflow-openshift.sh deploy   One-time (admin): namespace, secrets, Postgres, MLflow
#   ./mlflow-openshift.sh build    After a merge: build the branch tip locally and push it
#
# Configuration comes from the environment, falling back to a .env file next to this script
# (see .env.example). Variables already set in the environment win over .env.
set -euo pipefail
cd "$(dirname "$0")"

die() { echo "error: $*" >&2; exit 1; }

usage() {
  sed -n '2,5s/^# \{0,1\}//p' "$0"
  exit "${1:-0}"
}

load_env() {
  local key value
  [ -f .env ] || return 0
  while IFS='=' read -r key value || [ -n "$key" ]; do
    [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    [ -n "${!key+x}" ] && continue
    value=${value%\"}; value=${value#\"}
    export "$key=$value"
  done <.env
}

# Strips the default HTTPS port and any trailing slash so URLs compare reliably.
normalize_url() { local u=${1%/}; echo "${u%:443}"; }

# Pins the kube context and verifies it points at OPENSHIFT_API_URL, so a context switch in
# another terminal can't send us to the wrong cluster.
connect() {
  : "${OPENSHIFT_API_URL:?set OPENSHIFT_API_URL (e.g. https://api.<cluster-domain>:443); see .env.example}"
  NAMESPACE=${NAMESPACE:-mlflow}
  KUBE_CONTEXT=${KUBE_CONTEXT:-$(command oc config current-context 2>/dev/null)} \
    || die "no current kube context; run 'oc login' or set KUBE_CONTEXT"

  local actual
  actual=$(oc whoami --show-server 2>/dev/null) \
    || die "can't reach the cluster with context '$KUBE_CONTEXT'; run 'oc login $OPENSHIFT_API_URL'"
  [ "$(normalize_url "$actual")" = "$(normalize_url "$OPENSHIFT_API_URL")" ] \
    || die "context '$KUBE_CONTEXT' points at $actual, not OPENSHIFT_API_URL=$OPENSHIFT_API_URL. Run 'oc login $OPENSHIFT_API_URL' or set KUBE_CONTEXT."
}

oc() { command oc --context "$KUBE_CONTEXT" -n "${NAMESPACE:-mlflow}" "$@"; }

cmd_deploy() {
  connect
  command oc --context "$KUBE_CONTEXT" get namespace "$NAMESPACE" >/dev/null 2>&1 \
    || command oc --context "$KUBE_CONTEXT" create namespace "$NAMESPACE" >/dev/null

  # Existing secrets are left untouched so passwords don't rotate on re-run.
  if ! oc get secret mlflow-postgres >/dev/null 2>&1; then
    local db_user=mlflow db_pass auth_ini
    db_pass=$(openssl rand -hex 24)
    oc create secret generic mlflow-postgres \
      --from-literal=username="$db_user" --from-literal=password="$db_pass"

    oc create secret generic mlflow-server \
      --from-literal=backend-store-uri="postgresql://$db_user:$db_pass@postgres:5432/mlflow" \
      --from-literal=admin-password="$(openssl rand -hex 24)" \
      --from-literal=flask-secret-key="$(openssl rand -hex 24)"

    auth_ini=$(mktemp)
    cat >"$auth_ini" <<EOF
[mlflow]
default_permission = READ
database_uri = postgresql://$db_user:$db_pass@postgres:5432/mlflow_auth
admin_username = admin
authorization_function = mlflow.server.auth:authenticate_request_basic_auth
grant_default_workspace_access = false
EOF
    oc create secret generic mlflow-auth-config --from-file=basic_auth.ini="$auth_ini"
    rm -f "$auth_ini"
  fi

  oc apply -f imagestream.yaml -f postgres.yaml -f mlflow.yaml

  local host svc
  host=$(oc get route mlflow -o jsonpath='{.spec.host}')
  svc=mlflow.$NAMESPACE.svc
  oc create configmap mlflow-config \
    --from-literal=allowed-hosts="$host,mlflow,mlflow:5000,$svc,$svc:5000,$svc.cluster.local,$svc.cluster.local:5000,localhost,localhost:*" \
    --dry-run=client -o yaml | oc apply -f -

  echo "Route: https://$host"
  echo "Admin password: oc -n $NAMESPACE get secret mlflow-server -o jsonpath='{.data.admin-password}' | base64 -d"
  echo "Next: ./mlflow-openshift.sh build"
}

# Builds on this machine, never on the cluster: the UI build needs ~8 GB of heap. The push
# updates the mlflow ImageStream, whose trigger rolls out the Deployment (its db-upgrade init
# container applies new migrations first).
cmd_build() {
  : "${OPENSHIFT_REGISTRY:?set OPENSHIFT_REGISTRY (e.g. default-route-openshift-image-registry.apps.<cluster-domain>); see .env.example}"
  : "${MLFLOW_BRANCH:?set MLFLOW_BRANCH to the branch to build; see .env.example}"
  local repo=${MLFLOW_GIT_REPO:-https://github.com/mlflow/mlflow.git}
  local engine=${CONTAINER_ENGINE:-podman}
  local src=src token sha image mem
  connect

  command -v "$engine" >/dev/null || die "$engine not found (set CONTAINER_ENGINE=docker to use Docker)"
  token=$(oc whoami -t 2>/dev/null) \
    || die "no session token; log in with 'oc login' (username/password or token), not a certificate kubeconfig"
  [ "$(oc auth can-i update imagestreams/layers)" = yes ] \
    || die "you can't push to namespace $NAMESPACE; ask an admin to run: oc -n $NAMESPACE policy add-role-to-user system:image-builder $(oc whoami)"

  if [ "$engine" = podman ] && [ "$(uname)" = Darwin ]; then
    mem=$(podman machine inspect --format '{{.Resources.Memory}}' 2>/dev/null | head -1 || true)
    if [ -n "$mem" ] && [ "$mem" -lt 10240 ]; then
      echo "warning: podman machine has ${mem} MiB; the UI build likely needs 10 GiB+." >&2
      echo "         podman machine stop && podman machine set --memory 12288 && podman machine start" >&2
    fi
  fi

  if [ ! -d "$src/.git" ]; then
    git clone --depth 1 --branch "$MLFLOW_BRANCH" "$repo" "$src"
  else
    git -C "$src" remote set-url origin "$repo"
    git -C "$src" fetch --depth 1 origin "$MLFLOW_BRANCH"
    git -C "$src" reset --hard FETCH_HEAD
    git -C "$src" clean -fdx
  fi
  sha=$(git -C "$src" rev-parse --short HEAD)
  image=$OPENSHIFT_REGISTRY/$NAMESPACE/mlflow
  echo "Building $MLFLOW_BRANCH @ $sha -> $image"

  "$engine" build --platform linux/amd64 -f Dockerfile -t "$image:$sha" -t "$image:latest" "$src"

  echo "$token" | "$engine" login --username "$(oc whoami)" --password-stdin "$OPENSHIFT_REGISTRY"
  "$engine" push "$image:$sha"
  "$engine" push "$image:latest"
  echo "Pushed $image:$sha (and :latest); the Deployment rolls out automatically."
}

load_env
case "${1:-}" in
  deploy) cmd_deploy ;;
  build) cmd_build ;;
  -h|--help|help) usage ;;
  *) usage 1 ;;
esac
