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

After a merge to the branch, anyone with push access runs `./mlflow-openshift.sh build`. It
always builds the **current tip of the branch**, not your local checkout, so push/merge first.

## Prerequisites

- `oc`, `git`, and `podman` (or Docker, with `CONTAINER_ENGINE=docker`)
- An `oc login` session with a token (username/password or token login; a certificate-based
  kubeconfig can't log in to the registry)
- About 10 GB of memory for the container VM. For podman on macOS:
  `podman machine stop && podman machine set --memory 12288 && podman machine start`

On Apple Silicon the UI is compiled natively and only the Python install runs as amd64, so builds
stay reasonably fast.

## Configuration

All settings come from environment variables, or from a `.env` file in this directory (shell
variables win). Start from the template:

```bash
cp .env.example .env   # then fill in the values
```

| Variable | Required by | Description |
|---|---|---|
| `OPENSHIFT_API_URL` | `deploy`, `build` | Cluster API URL, as printed by `oc whoami --show-server` |
| `OPENSHIFT_REGISTRY` | `build` | External host of the internal registry route |
| `MLFLOW_BRANCH` | `build` | Branch to build |
| `NAMESPACE` | optional | Target namespace (default `mlflow`) |
| `KUBE_CONTEXT` | optional | kube context to use (default: your current context) |
| `MLFLOW_GIT_REPO` | optional | Repo to build from (default `https://github.com/mlflow/mlflow.git`) |
| `CONTAINER_ENGINE` | optional | `podman` (default) or `docker` |

Both subcommands check that the kube context points at `OPENSHIFT_API_URL` and stop otherwise,
so a context switch in another terminal can't send a deploy to the wrong cluster.

Run `./mlflow-openshift.sh help` for a usage summary.

`.env` is gitignored; don't commit cluster details.

## First-time setup (cluster admin, once)

```bash
./mlflow-openshift.sh deploy   # namespace, secrets, Postgres, MLflow Deployment/Service/Route
./mlflow-openshift.sh build    # first image; the Deployment starts once it lands
```

Secrets (DB password, admin password, Flask secret key) are generated randomly into the cluster
and never written to disk. Re-running `deploy` is safe and doesn't rotate them.

Grant each person (or a group) permission to push images:

```bash
oc -n mlflow policy add-role-to-user system:image-builder <username>
oc -n mlflow policy add-role-to-group system:image-builder <group>
```

## Shipping a new merge

```bash
./mlflow-openshift.sh build
oc -n mlflow rollout status deploy/mlflow
```

Images are tagged with the commit SHA as well as `latest`, so you can always tell what's running:

```bash
oc -n mlflow get istag -o custom-columns=TAG:.metadata.name,CREATED:.metadata.creationTimestamp
```

To try a different branch: `MLFLOW_BRANCH=<other-branch> ./mlflow-openshift.sh build`. Note that
migrations are forward-only; switching back to a branch with an older schema will fail at startup.

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
| `context ... points at ..., not OPENSHIFT_API_URL` | `oc login <OPENSHIFT_API_URL>` or set `KUBE_CONTEXT` |
| `no session token` | Log in with `oc login` using a password or token |
| `you can't push to namespace` | Ask an admin for `system:image-builder` (see above) |
| UI build killed / `JavaScript heap out of memory` | Give the podman/Docker VM 10 GB+ |
| Pod stuck in `Init` after a push | `oc -n mlflow logs deploy/mlflow -c db-upgrade` (migration failed) |
| `toomanyrequests` pulling base images | Already avoided: base images come from `public.ecr.aws` |

## Files

| File | Purpose |
|---|---|
| `mlflow-openshift.sh` | `deploy`: one-time setup of namespace, secrets, and manifests; `build`: build the image locally and push it |
| `Dockerfile` | Two stages: UI build (native), MLflow install (amd64) |
| `imagestream.yaml`, `postgres.yaml`, `mlflow.yaml` | Cluster manifests |
| `.env.example` | Configuration template |
