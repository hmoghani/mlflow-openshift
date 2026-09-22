# mlflow-openshift

Runs an MLflow tracking server on OpenShift, built from any branch of
[mlflow/mlflow](https://github.com/mlflow/mlflow), for live testing of unreleased changes.

- **Postgres** backend (tracking DB + a separate DB for the auth user store), on a PVC
- **Artifacts** served by MLflow, stored on a PVC
- **Basic auth** on both the UI and the REST API, exposed through a TLS Route
- **Automatic rollout**: pushing a new image rolls out the Deployment, and an init container runs
  `mlflow db upgrade` first so new migrations are applied

## How updates work

The image is built **on your machine** and pushed to the cluster's internal registry. It is never
built on the cluster: the MLflow UI build needs about 8 GB of memory, which can starve a shared
node.

```
build:    clone branch tip -> build linux/amd64 image locally -> push to registry
                                                                    |
      ImageStream updated -> Deployment rolls out -> db upgrade -> server starts
```

After a merge to the branch, anyone logged in to the cluster runs `./mlflow-openshift.sh build`.
It always builds the **current tip of the branch**, not your local checkout, so push/merge first.

## Prerequisites

- `oc`, `git`, and `podman` (or Docker, with `CONTAINER_ENGINE=docker`)
- An `oc login` session with a token (username/password or token login; a certificate-based
  kubeconfig can't log in to the registry)
- About 10 GB of memory for the container VM. For podman on macOS:
  `podman machine stop && podman machine set --memory 12288 && podman machine start`

On Apple Silicon the UI is compiled natively and only the Python install runs as amd64, so builds
stay reasonably fast.

## Configuration

None needed for day-to-day use. The script uses your current `oc login`, discovers the image
registry from the cluster, and reads the branch to build from a `mlflow-build` ConfigMap that
`deploy` writes. Everyone building into the namespace therefore builds the same branch.

`build` prints which cluster it's using and stops if that cluster has no `mlflow-build`
ConfigMap in the namespace, so it won't build into a cluster that wasn't set up with `deploy`.

Optional overrides come from environment variables, or a `.env` file in this directory (shell
variables win; see `.env.example`):

| Variable | Description |
|---|---|
| `OPENSHIFT_API_URL` | Refuse to run unless the current context points at this API URL |
| `KUBE_CONTEXT` | kube context to use (default: your current context) |
| `NAMESPACE` | Namespace of the deployment (default `mlflow`) |
| `MLFLOW_BRANCH` | Branch to build; with `deploy`, sets it for everyone |
| `MLFLOW_GIT_REPO` | Repo to build from (default `https://github.com/mlflow/mlflow.git`) |
| `OPENSHIFT_REGISTRY` | External host of the image registry route (default: discovered) |
| `CONTAINER_ENGINE` | `podman` (default) or `docker` |

`.env` is gitignored; don't commit cluster details. Run `./mlflow-openshift.sh help` for a usage
summary.

## First-time setup (once)

```bash
oc login <cluster-api-url>
MLFLOW_BRANCH=<branch> ./mlflow-openshift.sh deploy   # namespace, secrets, Postgres, MLflow
./mlflow-openshift.sh build                           # first image; the server starts once it lands
```

Secrets (DB password, admin password, Flask secret key) are generated randomly into the cluster
and never written to disk. Re-running `deploy` is safe and doesn't rotate them.

`build` needs the image registry's external route. If it reports none, enable it once with:

```bash
oc patch configs.imageregistry.operator.openshift.io/cluster --type merge -p '{"spec":{"defaultRoute":true}}'
```

## Shipping a new merge

```bash
./mlflow-openshift.sh build
oc -n mlflow rollout status deploy/mlflow
```

## Switching branches

For everyone (updates the `mlflow-build` ConfigMap):

```bash
MLFLOW_BRANCH=<other-branch> ./mlflow-openshift.sh deploy
./mlflow-openshift.sh build
```

For a single build only: `MLFLOW_BRANCH=<other-branch> ./mlflow-openshift.sh build`. The next
plain `build` goes back to the stored branch.

Migrations are forward-only: switching to a branch with an older schema fails at startup.

Images are tagged with the commit SHA as well as `latest`, so you can always tell what's running:

```bash
oc -n mlflow get istag -o custom-columns=TAG:.metadata.name,CREATED:.metadata.creationTimestamp
```

## Using the server

```bash
HOST=$(oc -n mlflow get route mlflow -o jsonpath='{.spec.host}')
PW=$(oc -n mlflow get secret mlflow-server -o jsonpath='{.data.admin-password}' | base64 -d)
```

- **UI:** `https://$HOST`, user `admin`
- **Python client:**
  ```bash
  export MLFLOW_TRACKING_URI=https://$HOST
  export MLFLOW_TRACKING_USERNAME=admin
  export MLFLOW_TRACKING_PASSWORD=$PW
  ```

Create per-person users instead of sharing `admin`; see the
[MLflow auth docs](https://mlflow.org/docs/latest/self-hosting/security/basic-http-auth/).

## Troubleshooting

| Symptom | Fix |
|---|---|
| `no MLflow deployment in namespace ...` | Wrong cluster: check the printed `Cluster:` line and `oc login` to the right one |
| `context ... points at ..., not OPENSHIFT_API_URL` | `oc login <OPENSHIFT_API_URL>` or set `KUBE_CONTEXT` |
| `no session token` | Log in with `oc login` using a password or token |
| `the image registry has no external route` | Enable it (see First-time setup) |
| UI build killed / `JavaScript heap out of memory` | Give the podman/Docker VM 10 GB+ |
| Pod stuck in `Init` after a push | `oc -n mlflow logs deploy/mlflow -c db-upgrade` (migration failed) |
| `toomanyrequests` pulling base images | Already avoided: base images come from `public.ecr.aws` |

## Files

| File | Purpose |
|---|---|
| `mlflow-openshift.sh` | `deploy`: one-time setup of namespace, secrets, and manifests; `build`: build the image locally and push it |
| `Dockerfile` | Two stages: UI build (native), MLflow install (amd64) |
| `imagestream.yaml`, `postgres.yaml`, `mlflow.yaml` | Cluster manifests |
| `.env.example` | Optional overrides |
