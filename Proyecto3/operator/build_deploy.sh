#!/usr/bin/env bash
# Construye la imagen del operador (linux/amd64), la publica en Zot y la instala en el
# clúster: CRDs, RBAC y el Deployment del manager en el namespace mumnk8s-operator-system.
# Uso: TAG=v2 ./build_deploy.sh
set -euo pipefail
cd "$(dirname "$0")"
source ../scripts/config.env
source "$SECRETS_DIR/zot.env"

IMG="$ZOT_DOMAIN/mumnk8s/mumnk8s-operator:${TAG:-v1}"
echo "$ZOT_PASS" | docker login "$ZOT_DOMAIN" -u "$ZOT_USER" --password-stdin >/dev/null
docker buildx build --platform linux/amd64 -t "$IMG" --push .
make deploy IMG="$IMG"
kubectl -n mumnk8s-operator-system rollout status deploy/mumnk8s-operator-controller-manager
