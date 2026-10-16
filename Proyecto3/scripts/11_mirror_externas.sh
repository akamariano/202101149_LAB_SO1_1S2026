#!/usr/bin/env bash
# Copia a Zot las imágenes de terceros (RabbitMQ, etc.) para que el clúster descargue
# TODO desde el registry propio, como pide el enunciado.
# imagetools copia de registry a registry sin hacer pull local. Solo se copia linux/amd64
# (la arquitectura de los nodos N1): copiar todas las arquitecturas a la vez saturaba a
# Zot en la VM pequeña y fallaba con "stream error: INTERNAL_ERROR".
set -euo pipefail
source "$(dirname "$0")/config.env"
source "$SECRETS_DIR/zot.env"

# origen -> nombre dentro de Zot
IMAGENES=(
  "docker.io/library/rabbitmq:4.1-management-alpine mumnk8s/rabbitmq:4.1-management-alpine"
  "docker.io/valkey/valkey:8.1-alpine mumnk8s/valkey:8.1-alpine"
)

docker info &>/dev/null || { echo "Abre Docker Desktop primero."; exit 1; }
echo "$ZOT_PASS" | docker login "$ZOT_DOMAIN" -u "$ZOT_USER" --password-stdin >/dev/null

for par in "${IMAGENES[@]}"; do
  read -r src dst <<<"$par"
  echo "→ $src  =>  $ZOT_DOMAIN/$dst"
  docker buildx imagetools create --platform linux/amd64 --tag "$ZOT_DOMAIN/$dst" "$src"
done
