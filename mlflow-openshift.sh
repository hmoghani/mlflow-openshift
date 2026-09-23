#!/usr/bin/env bash
# Runs an MLflow server on OpenShift, built from a branch of mlflow/mlflow. See README.md.
#
#   MLFLOW_BRANCH=<branch> ./mlflow-openshift.sh deploy   One-time setup (or switch branch)
#   ./mlflow-openshift.sh build                           After a merge: build and roll out
#   ./mlflow-openshift.sh build --local <path>            Build your local checkout, uncommitted
#                                                         changes included
#   Set NAMESPACE=<name> on all of them to use your own namespace (default: mlflow).
#
# Uses your current `oc login`. The branch to build is stored on the cluster by `deploy`, so
# `build` needs no configuration. Optional overrides come from the environment, falling back to
# a .env file next to this script (see .env.example).
set -euo pipefail
# Kept so relative --local paths resolve against where the script was run from.
CALLER_PWD=$PWD
cd "$(dirname "$0")"

die() { echo "error: $*" >&2; exit 1; }

usage() {
  sed -n '2,8s/^# \{0,1\}//p' "$0"
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

# Pins the kube context for the whole run, so a context switch in another terminal can't
# redirect us mid-run. If OPENSHIFT_API_URL is set, also require the context to point at it.
connect() {
  NAMESPACE=${NAMESPACE:-mlflow}
  KUBE_CONTEXT=${KUBE_CONTEXT:-$(command oc config current-context 2>/dev/null)} \
    || die "no current kube context; run 'oc login <cluster-api-url>' first"

  local actual
  actual=$(oc whoami --show-server 2>/dev/null) \
    || die "can't reach the cluster with context '$KUBE_CONTEXT'; run 'oc login <cluster-api-url>'"
  if [ -n "${OPENSHIFT_API_URL:-}" ] \
    && [ "$(normalize_url "$actual")" != "$(normalize_url "$OPENSHIFT_API_URL")" ]; then
    die "context '$KUBE_CONTEXT' points at $actual, not OPENSHIFT_API_URL=$OPENSHIFT_API_URL"
  fi
  echo "Cluster: $actual (namespace $NAMESPACE)"
}

oc() { command oc --context "$KUBE_CONTEXT" -n "${NAMESPACE:-mlflow}" "$@"; }

# Reads a key from the mlflow-build ConfigMap that `deploy` writes.
build_setting() { oc get configmap mlflow-build -o jsonpath="{.data.$1}" 2>/dev/null; }

cmd_deploy() {
  connect
  local branch=${MLFLOW_BRANCH:-$(build_setting branch)}
  local repo=${MLFLOW_GIT_REPO:-$(build_setting git-repo)}
  repo=${repo:-https://github.com/mlflow/mlflow.git}
  [ -n "$branch" ] || die "set MLFLOW_BRANCH to the branch to deploy, e.g. MLFLOW_BRANCH=<branch> $0 deploy"

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

  # What `build` builds; shared by everyone who deploys to this namespace.
  oc create configmap mlflow-build --from-literal=branch="$branch" --from-literal=git-repo="$repo" \
    --dry-run=client -o yaml | oc apply -f -

  echo "Route: https://$host"
  echo "Tracking branch: $branch ($repo)"
  echo "Admin password: oc -n $NAMESPACE get secret mlflow-server -o jsonpath='{.data.admin-password}' | base64 -d"
  if [ "$NAMESPACE" = mlflow ]; then
    echo "Next: $0 build"
  else
    echo "Next: NAMESPACE=$NAMESPACE $0 build   (or put NAMESPACE=$NAMESPACE in .env)"
  fi
}

# Copies a local checkout's working tree into $LOCAL_SRC as git sees it: tracked files
# (including uncommitted edits) plus untracked files that aren't gitignored. Gitignored content
# such as node_modules, .venv, and build outputs stays out of the image. Sets the build_* vars.
snapshot_local() {
  local path=$1 root
  case "$path" in
    "~"/*) path=$HOME/${path#"~/"} ;;
    /*) ;;
    *) path=$CALLER_PWD/$path ;;
  esac
  root=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null) || die "--local: $path is not a git checkout"
  [ -f "$root/pyproject.toml" ] && [ -f "$root/mlflow/server/js/package.json" ] \
    || die "--local: $root doesn't look like an mlflow checkout"

  rm -rf "$LOCAL_SRC" && mkdir -p "$LOCAL_SRC"
  git -C "$root" ls-files -z --cached --others --exclude-standard \
    | while IFS= read -r -d '' f; do if [ -e "$root/$f" ]; then printf '%s\0' "$f"; fi; done \
    | tar -C "$root" --null -T - -cf - | tar -C "$LOCAL_SRC" -xf -

  # Submodules (e.g. mlflow/assistant/skills) ship inside the mlflow package. Initialized ones
  # were copied above; for any the checkout hasn't initialized, fetch the commit it records.
  local key subpath name url sub_sha
  while read -r key subpath; do
    name=${key#submodule.}; name=${name%.path}
    sub_sha=$(git -C "$root" ls-files -s -- "$subpath" | awk '$1 == "160000" {print $2}')
    [ -n "$sub_sha" ] || continue
    if [ -z "$(ls -A "$root/$subpath" 2>/dev/null)" ]; then
      url=$(git -C "$root" config -f .gitmodules "submodule.$name.url")
      echo "Fetching submodule $subpath @ ${sub_sha:0:7} (not initialized in your checkout)"
      rm -rf "${LOCAL_SRC:?}/$subpath" && git init -q "$LOCAL_SRC/$subpath"
      git -C "$LOCAL_SRC/$subpath" fetch -q --depth 1 "$url" "$sub_sha"
      git -C "$LOCAL_SRC/$subpath" checkout -q FETCH_HEAD
    fi
    rm -rf "${LOCAL_SRC:?}/$subpath/.git"
  done < <(git -C "$root" config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null || true)

  local dirty=""
  [ -z "$(git -C "$root" status --porcelain)" ] || dirty=-dirty
  build_branch=$(git -C "$root" rev-parse --abbrev-ref HEAD)
  build_commit=$(git -C "$root" rev-parse HEAD)$dirty
  build_tag=local-$(git -C "$root" rev-parse --short HEAD)$dirty
  build_repo=local:$(git -C "$root" remote get-url origin 2>/dev/null || echo "$root")
  echo "Snapshot of $root ($build_branch${dirty:+, with uncommitted changes})"
}

# Builds on this machine, never on the cluster: the UI build needs ~8 GB of heap. The push
# updates the mlflow ImageStream, whose trigger rolls out the Deployment (its db-upgrade init
# container applies new migrations first).
cmd_build() {
  local local_path=${MLFLOW_LOCAL_PATH:-}
  while [ $# -gt 0 ]; do
    case "$1" in
      --local) [ $# -ge 2 ] || die "--local needs a path to an mlflow checkout"; local_path=$2; shift 2 ;;
      --local=*) local_path=${1#--local=}; shift ;;
      *) die "unknown build option: $1 (see '$0 help')" ;;
    esac
  done

  local engine=${CONTAINER_ENGINE:-podman}
  local src registry token image mem build_branch build_commit build_tag build_repo
  connect

  # Doubles as the wrong-cluster check: only a cluster set up by `deploy` has this ConfigMap.
  oc get configmap mlflow-build >/dev/null 2>&1 \
    || die "no MLflow deployment in namespace $NAMESPACE on this cluster; wrong cluster, or run '$0 deploy' first"
  if [ -z "$local_path" ]; then
    build_branch=${MLFLOW_BRANCH:-$(build_setting branch)}
    build_repo=${MLFLOW_GIT_REPO:-$(build_setting git-repo)}
    [ -n "$build_branch" ] && [ -n "$build_repo" ] || die "mlflow-build ConfigMap is incomplete; re-run '$0 deploy'"
  fi

  registry=${OPENSHIFT_REGISTRY:-$(command oc --context "$KUBE_CONTEXT" -n openshift-image-registry \
    get route default-route -o jsonpath='{.spec.host}' 2>/dev/null)} || true
  [ -n "$registry" ] || die "the image registry has no external route; enable it with: oc patch configs.imageregistry.operator.openshift.io/cluster --type merge -p '{\"spec\":{\"defaultRoute\":true}}'"

  command -v "$engine" >/dev/null || die "$engine not found (set CONTAINER_ENGINE=docker to use Docker)"
  token=$(oc whoami -t 2>/dev/null) \
    || die "no session token; log in with 'oc login' (username/password or token), not a certificate kubeconfig"
  [ "$(oc auth can-i update imagestreams/layers)" = yes ] \
    || die "you can't push images to namespace $NAMESPACE"

  if [ "$engine" = podman ] && [ "$(uname)" = Darwin ]; then
    mem=$(podman machine inspect --format '{{.Resources.Memory}}' 2>/dev/null | head -1 || true)
    if [ -n "$mem" ] && [ "$mem" -lt 10240 ]; then
      echo "warning: podman machine has ${mem} MiB; the UI build likely needs 10 GiB+." >&2
      echo "         podman machine stop && podman machine set --memory 12288 && podman machine start" >&2
    fi
  fi

  if [ -n "$local_path" ]; then
    src=$LOCAL_SRC
    snapshot_local "$local_path"
    echo "warning: if your local changes add DB migrations, this namespace's database moves ahead of" >&2
    echo "         '$(build_setting branch)' and its next normal build won't start. Use your own namespace" >&2
    echo "         (NAMESPACE=mlflow-<you>) for that kind of work." >&2
  else
    src=src
    # Submodules (e.g. mlflow/assistant/skills) ship inside the mlflow package, so fetch them too.
    if [ ! -d "$src/.git" ]; then
      git clone --depth 1 --recurse-submodules --shallow-submodules --branch "$build_branch" "$build_repo" "$src"
    else
      git -C "$src" remote set-url origin "$build_repo"
      git -C "$src" fetch --depth 1 origin "$build_branch"
      git -C "$src" reset --hard FETCH_HEAD
      git -C "$src" submodule update --init --recursive --depth 1
      git -C "$src" clean -ffdx
    fi
    build_commit=$(git -C "$src" rev-parse HEAD)
    build_tag=$(git -C "$src" rev-parse --short HEAD)
  fi
  image=$registry/$NAMESPACE/mlflow
  echo "Building $build_branch @ $build_tag"

  "$engine" build --platform linux/amd64 -f Dockerfile \
    --build-arg MLFLOW_BUILD_REPO="$build_repo" \
    --build-arg MLFLOW_BUILD_BRANCH="$build_branch" \
    --build-arg MLFLOW_BUILD_COMMIT="$build_commit" \
    -t "$image:$build_tag" -t "$image:latest" "$src"

  echo "$token" | "$engine" login --username "$(oc whoami)" --password-stdin "$registry"
  "$engine" push "$image:$build_tag"
  "$engine" push "$image:latest"
  echo "Pushed $build_branch @ $build_tag; the Deployment rolls out automatically."
  echo "Watch it: oc -n $NAMESPACE rollout status deploy/mlflow"
}

LOCAL_SRC=src-local
load_env
case "${1:-}" in
  deploy) cmd_deploy ;;
  build) shift; cmd_build "$@" ;;
  -h|--help|help) usage ;;
  *) usage 1 ;;
esac
