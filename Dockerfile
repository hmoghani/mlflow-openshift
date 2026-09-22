# Built locally (mlflow-openshift.sh build), never on the cluster: the UI build needs ~8 GB of heap.
# Base images come from ECR Public's Docker Hub mirror to avoid Docker Hub pull limits.

# Stage 1: the UI bundle is arch-independent, so build it natively on the build host
FROM --platform=$BUILDPLATFORM public.ecr.aws/docker/library/node:24-slim AS ui
COPY . /src
WORKDIR /src/mlflow/server/js
RUN node yarn/releases/yarn-4.12.0.cjs install --immutable \
 && node yarn/releases/yarn-4.12.0.cjs build

# Stage 2: install MLflow for the target platform with the prebuilt UI bundled in
FROM public.ecr.aws/docker/library/python:3.12-slim
ENV PIP_NO_CACHE_DIR=1 PYTHONUNBUFFERED=1 HOME=/tmp
COPY . /src
COPY --from=ui /src/mlflow/server/js/build /src/mlflow/server/js/build
RUN pip install "/src[db,auth,genai]" && rm -rf /src
# OpenShift runs with an arbitrary UID in group 0
RUN mkdir -p /mlflow && chgrp -R 0 /mlflow && chmod -R g=u /mlflow
WORKDIR /mlflow
USER 1001
EXPOSE 5000

# Where this image was built from (set by `mlflow-openshift.sh build`); readable in the pod via
# `env | grep MLFLOW_BUILD` and on the image via its labels.
ARG MLFLOW_BUILD_REPO=unknown
ARG MLFLOW_BUILD_BRANCH=unknown
ARG MLFLOW_BUILD_COMMIT=unknown
ENV MLFLOW_BUILD_REPO=$MLFLOW_BUILD_REPO \
    MLFLOW_BUILD_BRANCH=$MLFLOW_BUILD_BRANCH \
    MLFLOW_BUILD_COMMIT=$MLFLOW_BUILD_COMMIT
LABEL org.opencontainers.image.source=$MLFLOW_BUILD_REPO \
      org.opencontainers.image.revision=$MLFLOW_BUILD_COMMIT \
      mlflow-openshift.branch=$MLFLOW_BUILD_BRANCH
