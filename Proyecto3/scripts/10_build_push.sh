#!/usr/bin/env bash
# Construye las imágenes para linux/amd64 y las publica en Zot.
# Uso: ./scripts/10_build_push.sh [servicio...]     (sin argumentos: todas)
#      TAG=v2 ./scripts/10_build_push.sh rust-api
set -euo pipefail
source "$(dirname "$0")/config.env"
source "$SECRETS_DIR/zot.env"

TAG="${TAG:-v1}"
REG="$ZOT_DOMAIN/mumnk8s"
GO_SERVICES="api-rest grpc-client grpc-server"
ALL="rust-api $GO_SERVICES"
TARGETS="${*:-$ALL}"

docker info &>/dev/null || { echo "Abre Docker Desktop primero."; exit 1; }
echo "$ZOT_PASS" | docker login "$ZOT_DOMAIN" -u "$ZOT_USER" --password-stdin >/dev/null

for svc in $TARGETS; do
  img="$REG/$svc:$TAG"
  echo "→ $img"
  if [ "$svc" = "rust-api" ]; then
    docker buildx build --platform linux/amd64 -t "$img" --push "$P3_ROOT/rust-api"
  else
    docker buildx build --platform linux/amd64 --build-arg SERVICE="$svc" -t "$img" --push "$P3_ROOT/go-services"
  fi
done

echo
echo "Catálogo de Zot:"
curl -s "https://$ZOT_DOMAIN/v2/_catalog"; echo
