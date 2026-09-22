# mlflow-openshift

Run an MLflow tracking server on OpenShift, built from any branch of
[mlflow/mlflow](https://github.com/mlflow/mlflow), for live testing of unreleased changes.

## Quick start

You need `oc`, `git`, and `podman` (or Docker), and about 10 GB of memory for the container VM
([details](#prerequisites)).

```bash
# 1. Log in to the cluster
oc login <cluster-api-url>

# 2. Set the variables
export MLFLOW_BRANCH=<branch>   # branch of mlflow/mlflow to run
export NAMESPACE=mlflow         # optional; mlflow is the default

# 3. First time only: create the namespace, database, and server
./mlflow-openshift.sh deploy

# 4. Build the branch on your machine and roll it out (takes a while the first time)
./mlflow-openshift.sh build
oc -n $NAMESPACE rollout status deploy/mlflow
```

Then open it:

```bash
echo "https://$(oc -n $NAMESPACE get route mlflow -o jsonpath='{.spec.host}')"
oc -n $NAMESPACE get secret mlflow-server -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Log in to the UI as `admin` with that password. For the Python client:

```bash
export MLFLOW_TRACKING_URI=https://$(oc -n $NAMESPACE get route mlflow -o jsonpath='{.spec.host}')
export MLFLOW_TRACKING_USERNAME=admin
export MLFLOW_TRACKING_PASSWORD=$(oc -n $NAMESPACE get secret mlflow-server -o jsonpath='{.data.admin-password}' | base64 -d)
```

## After a merge

Anyone logged in to the cluster ships the latest commit with:

```bash
./mlflow-openshift.sh build
```

No variables needed: `deploy` stored the branch on the cluster, so everyone builds the same one.
It builds the **tip of the branch on GitHub**, not your local checkout, so merge or push first.
Set `NAMESPACE` if the deployment isn't in `mlflow`.

Joining an existing deployment? Skip step 3; `oc login` and `build` are all you need.

## Variables

All optional except `MLFLOW_BRANCH` on the first `deploy`. Set them with `export`, or put them in
a `.env` file next to the script (see `.env.example`); exported variables win over `.env`.

| Variable | Default | Description |
|---|---|---|
| `MLFLOW_BRANCH` | stored on the cluster | Branch to build. With `deploy`, sets it for everyone; with `build`, only for that build |
| `NAMESPACE` | `mlflow` | Namespace of the deployment |
| `MLFLOW_GIT_REPO` | `https://github.com/mlflow/mlflow.git` | Repo to build from, e.g. your fork |
| `KUBE_CONTEXT` | your current context | kube context to use |
| `OPENSHIFT_API_URL` | not set | If set, refuse to run unless the context points at this API URL |
| `OPENSHIFT_REGISTRY` | discovered from the cluster | External host of the image registry route |
| `CONTAINER_ENGINE` | `podman` | `podman` or `docker` |

Every command prints the cluster and namespace it's using. `build` stops if that namespace has no
deployment, so it won't push to the wrong cluster by accident.

## Switching branches

For everyone:

```bash
MLFLOW_BRANCH=<other-branch> ./mlflow-openshift.sh deploy
./mlflow-openshift.sh build
```

For one build only: `MLFLOW_BRANCH=<other-branch> ./mlflow-openshift.sh build`. The next plain
`build` goes back to the stored branch.

Migrations only go forward: a branch with an older database schema than the one deployed fails
at startup.

## Your own namespace

To test without touching the shared deployment, run a separate instance with its own database,
admin password, branch, and Route:

```bash
export NAMESPACE=mlflow-<you>
MLFLOW_BRANCH=<branch> ./mlflow-openshift.sh deploy
./mlflow-openshift.sh build
```

Keep `NAMESPACE` set (or put it in `.env`) for every command that targets it. Remove the instance
and all its data with `oc delete namespace mlflow-<you>`.

## How it works

```
build:  clone branch tip -> build linux/amd64 image locally -> push to cluster registry
                                                                    |
        ImageStream updated -> Deployment rolls out -> mlflow db upgrade -> server starts
```

- **Postgres** stores tracking data, plus a separate database for users and permissions, on a PVC.
- **Artifacts** are served by MLflow and stored on a PVC.
- **Basic auth** protects both the UI and the REST API, exposed through a TLS Route.
- **Builds run on your machine, never on the cluster.** The MLflow UI build needs about 8 GB of
  memory, which can starve a shared node. On Apple Silicon the UI compiles natively and only the
  Python install runs as amd64.
- **Images** are tagged with the commit SHA and `latest`. See what's deployed with
  `oc -n $NAMESPACE get istag`.
- **Secrets** (database password, admin password, Flask secret key) are generated into the cluster
  by `deploy` and never written to disk. Re-running `deploy` doesn't rotate them.

## Prerequisites

- `oc`, `git`, and `podman`, or Docker with `CONTAINER_ENGINE=docker`
- A token-based `oc login` (username/password or token). A certificate-based kubeconfig can't log
  in to the image registry.
- About 10 GB of memory for the container VM. For podman on macOS:
  `podman machine stop && podman machine set --memory 12288 && podman machine start`
- The image registry's external route. If `build` reports it's missing, enable it once:
  `oc patch configs.imageregistry.operator.openshift.io/cluster --type merge -p '{"spec":{"defaultRoute":true}}'`

## Troubleshooting

| Symptom | Fix |
|---|---|
| `no MLflow deployment in namespace ...` | Check the printed `Cluster:` line and `NAMESPACE`; `oc login` to the right cluster, or run `deploy` first |
| `set MLFLOW_BRANCH to the branch to deploy` | First `deploy` in this namespace: `export MLFLOW_BRANCH=<branch>` |
| `context ... points at ..., not OPENSHIFT_API_URL` | `oc login <OPENSHIFT_API_URL>` or set `KUBE_CONTEXT` |
| `no session token` | Log in with `oc login` using a password or token |
| `the image registry has no external route` | Enable it (see [Prerequisites](#prerequisites)) |
| UI build killed / `JavaScript heap out of memory` | Give the podman/Docker VM 10 GB+ |
| Pod stuck in `Init` after a build | `oc -n $NAMESPACE logs deploy/mlflow -c db-upgrade` (migration failed) |

For more users than the shared `admin`, see the
[MLflow auth docs](https://mlflow.org/docs/latest/self-hosting/security/basic-http-auth/).

## Files

| File | Purpose |
|---|---|
| `mlflow-openshift.sh` | `deploy`: namespace, secrets, and manifests. `build`: build the image locally and push it |
| `Dockerfile` | Two stages: UI build (native), MLflow install (amd64) |
| `imagestream.yaml`, `postgres.yaml`, `mlflow.yaml` | Cluster manifests |
| `.env.example` | Optional overrides |
