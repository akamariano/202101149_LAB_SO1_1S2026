#!/usr/bin/env bash
# Bloque 1c: valida el ciclo completo  Mac --push--> Zot (HTTPS) <--pull-- GKE
set -euo pipefail
source "$(dirname "$0")/config.env"
source "$SECRETS_DIR/zot.env"

docker info &>/dev/null || { echo "Abre Docker Desktop primero."; exit 1; }

echo "→ docker login a Zot"
echo "$ZOT_PASS" | docker login "$ZOT_DOMAIN" -u "$ZOT_USER" --password-stdin

echo "→ Imagen de prueba (amd64, porque los nodos N1 son x86)"
docker pull --platform linux/amd64 nginx:alpine
docker tag nginx:alpine "$ZOT_DOMAIN/prueba/nginx:v1"
docker push "$ZOT_DOMAIN/prueba/nginx:v1"

echo "→ Catálogo de Zot:"
curl -s "https://$ZOT_DOMAIN/v2/_catalog"; echo

echo "→ Pod en GKE que descarga la imagen desde Zot (sin imagePullSecret: lectura anónima)"
kubectl delete pod prueba-zot --ignore-not-found
kubectl run prueba-zot --image "$ZOT_DOMAIN/prueba/nginx:v1" --restart Never
kubectl wait --for=condition=Ready pod/prueba-zot --timeout=120s
kubectl describe pod prueba-zot | grep -E "Image:|Pulled|Successfully"
kubectl delete pod prueba-zot
echo "✔ Bloque 1 completo: GKE consume imágenes desde Zot por HTTPS"
